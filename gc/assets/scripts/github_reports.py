#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import validate_verdict_report

try:
    import yaml
except ImportError:  # pragma: no cover
    yaml = None


FRONT_MATTER_RE = re.compile(r"\A---\n(?P<body>.*?)\n---(?:\n|\Z)", re.DOTALL)
BODY_HASH_RE = re.compile(r"\Asha256:[0-9a-f]{64}\Z")
VALID_TRIAGE_VERDICTS = {
    "reproduced",
    "not_reproduced",
    "needs_info",
    "not_a_bug",
    "duplicate",
    "security_sensitive",
}
VALID_PRIORITIES = {"p0", "p1", "p2", "p3"}
VALID_ACTIONS = {"fix", "test_hardening", "close", "ask_reporter", "defer", "security_process"}
VALID_ACTIONS_BY_VERDICT = {
    "reproduced": {"fix", "defer"},
    "not_reproduced": {"test_hardening", "defer"},
    "needs_info": {"ask_reporter"},
    "not_a_bug": {"close"},
    "duplicate": {"close"},
    "security_sensitive": {"security_process"},
}


class ValidationError(Exception):
    pass


@dataclass(frozen=True)
class TriageReport:
    schema: str
    repo: str
    issue_number: int
    body_hash: str
    verdict: str
    priority: str
    recommended_next_action: str
    reproduction_artifact_path: str
    reproduction_diff_path: str


def validate_triage_report_text(
    text: str,
    *,
    expected_repo: str = "",
    expected_issue_number: int = 0,
    expected_body_hash: str = "",
) -> TriageReport:
    if yaml is None:
        raise ValidationError("PyYAML is required to parse triage reports")
    match = FRONT_MATTER_RE.match(text)
    if not match:
        raise ValidationError("triage report must start with YAML front matter")
    data = yaml.safe_load(match.group("body")) or {}
    if not isinstance(data, dict):
        raise ValidationError("triage report front matter must be a mapping")

    schema = required_string(data, "schema")
    repo = required_string(data, "repo")
    issue_number = required_int(data, "issue_number")
    body_hash = required_string(data, "body_hash")
    verdict = required_string(data, "verdict")
    priority = required_string(data, "priority")
    recommended_next_action = required_string(data, "recommended_next_action")
    reproduction_artifact_path = optional_string(data, "reproduction_artifact_path")
    reproduction_diff_path = optional_string(data, "reproduction_diff_path")

    if schema != "gc.github-issue-triage-report.v1":
        raise ValidationError(f"schema must be gc.github-issue-triage-report.v1, got {schema!r}")
    if issue_number <= 0:
        raise ValidationError("issue_number must be a positive integer")
    if not BODY_HASH_RE.match(body_hash):
        raise ValidationError("body_hash must be sha256:<64 lowercase hex chars>")
    if verdict not in VALID_TRIAGE_VERDICTS:
        raise ValidationError(f"verdict must be one of {sorted(VALID_TRIAGE_VERDICTS)}, got {verdict!r}")
    if priority not in VALID_PRIORITIES:
        raise ValidationError(f"priority must be one of {sorted(VALID_PRIORITIES)}, got {priority!r}")
    if recommended_next_action not in VALID_ACTIONS:
        raise ValidationError(f"recommended_next_action must be one of {sorted(VALID_ACTIONS)}")
    if recommended_next_action not in VALID_ACTIONS_BY_VERDICT[verdict]:
        raise ValidationError(f"recommended_next_action {recommended_next_action!r} is invalid for verdict {verdict!r}")
    if expected_repo and repo != expected_repo:
        raise ValidationError(f"repo must be {expected_repo!r}, got {repo!r}")
    if expected_issue_number and issue_number != expected_issue_number:
        raise ValidationError(f"issue_number must be {expected_issue_number}, got {issue_number}")
    if expected_body_hash and body_hash != expected_body_hash:
        raise ValidationError(f"body_hash must be {expected_body_hash!r}, got {body_hash!r}")
    return TriageReport(
        schema=schema,
        repo=repo,
        issue_number=issue_number,
        body_hash=body_hash,
        verdict=verdict,
        priority=priority,
        recommended_next_action=recommended_next_action,
        reproduction_artifact_path=reproduction_artifact_path,
        reproduction_diff_path=reproduction_diff_path,
    )


def review_outcome(verdict: str, severity: str) -> str:
    if verdict == "pass" and severity == "none":
        return "approve"
    if verdict == "fail" and severity == "minor":
        return "comment"
    if verdict == "fail" and severity == "major":
        return "request_changes"
    if verdict == "fail" and severity == "blocker":
        return "block"
    raise ValidationError(f"unsupported review verdict/severity combination: {verdict}/{severity}")


def render_pr_review_comment(
    report_path: Path,
    *,
    outcome: str,
    head_sha: str = "",
    artifact_ref: str = "",
    human_approved: bool = False,
) -> str:
    report = validate_verdict_report.validate_report_text(report_path.read_text(encoding="utf-8"), expected_kind="review")
    if outcome != review_outcome(report.verdict, report.severity):
        raise ValidationError(f"outcome {outcome!r} does not match review report {report.verdict}/{report.severity}")
    gate_text = "human approved" if human_approved else "not human approved"
    return (
        f"<!-- gc:github-pr-review head_sha={head_sha} outcome={outcome} -->\n"
        "## GC PR Review\n\n"
        f"- outcome: {outcome}\n"
        f"- report: {report.verdict}/{report.severity}\n"
        f"- gate: {gate_text}\n"
        f"- artifact: {artifact_ref or str(report_path)}\n"
    )


def render_issue_fix_status(
    *,
    state: str,
    summary: str,
    run_id: str = "",
    pr_url: str = "",
    artifact_ref: str = "",
) -> str:
    if not state.strip():
        raise ValidationError("state must not be empty")
    if not summary.strip():
        raise ValidationError("summary must not be empty")
    lines = [
        f"<!-- gc:github-issue-fix-status run_id={run_id} state={state} -->",
        "## GC Issue Fix",
        "",
        f"- state: {state}",
        f"- summary: {summary.strip()}",
    ]
    if pr_url:
        lines.append(f"- pr: {pr_url}")
    if artifact_ref:
        lines.append(f"- artifact: {artifact_ref}")
    return "\n".join(lines) + "\n"


def required_string(data: dict[str, Any], key: str) -> str:
    value = data.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValidationError(f"{key} must be a non-empty string")
    return value.strip()


def optional_string(data: dict[str, Any], key: str) -> str:
    value = data.get(key, "")
    if value is None:
        return ""
    if not isinstance(value, str):
        raise ValidationError(f"{key} must be a string")
    return value.strip()


def required_int(data: dict[str, Any], key: str) -> int:
    value = data.get(key)
    if isinstance(value, int):
        return value
    raise ValidationError(f"{key} must be an integer")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate and render GitHub workflow reports")
    subparsers = parser.add_subparsers(dest="command", required=True)

    triage_parser = subparsers.add_parser("validate-triage")
    triage_parser.add_argument("path", type=Path)
    triage_parser.add_argument("--repo", default="")
    triage_parser.add_argument("--issue-number", type=int, default=0)
    triage_parser.add_argument("--body-hash", default="")

    outcome_parser = subparsers.add_parser("review-outcome")
    outcome_parser.add_argument("path", type=Path)

    review_comment_parser = subparsers.add_parser("render-review-comment")
    review_comment_parser.add_argument("report_path", type=Path)
    review_comment_parser.add_argument("--output", type=Path, required=True)
    review_comment_parser.add_argument("--head-sha", default="")
    review_comment_parser.add_argument("--artifact-ref", default="")
    review_comment_parser.add_argument("--human-approved", action="store_true")

    fix_status_parser = subparsers.add_parser("render-issue-fix-status")
    fix_status_parser.add_argument("--state", required=True)
    fix_status_parser.add_argument("--summary", required=True)
    fix_status_parser.add_argument("--output", type=Path, required=True)
    fix_status_parser.add_argument("--run-id", default="")
    fix_status_parser.add_argument("--pr-url", default="")
    fix_status_parser.add_argument("--artifact-ref", default="")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        if args.command == "validate-triage":
            report = validate_triage_report_text(
                args.path.read_text(encoding="utf-8"),
                expected_repo=args.repo,
                expected_issue_number=args.issue_number,
                expected_body_hash=args.body_hash,
            )
            output = {"ok": True, "verdict": report.verdict, "recommended_next_action": report.recommended_next_action}
        elif args.command == "review-outcome":
            report = validate_verdict_report.validate_report_text(args.path.read_text(encoding="utf-8"), expected_kind="review")
            output = {"ok": True, "outcome": review_outcome(report.verdict, report.severity)}
        elif args.command == "render-review-comment":
            report = validate_verdict_report.validate_report_text(args.report_path.read_text(encoding="utf-8"), expected_kind="review")
            outcome = review_outcome(report.verdict, report.severity)
            args.output.write_text(
                render_pr_review_comment(
                    args.report_path,
                    outcome=outcome,
                    head_sha=args.head_sha,
                    artifact_ref=args.artifact_ref,
                    human_approved=args.human_approved,
                ),
                encoding="utf-8",
            )
            output = {"ok": True, "outcome": outcome, "output": str(args.output)}
        elif args.command == "render-issue-fix-status":
            args.output.write_text(
                render_issue_fix_status(
                    state=args.state,
                    summary=args.summary,
                    run_id=args.run_id,
                    pr_url=args.pr_url,
                    artifact_ref=args.artifact_ref,
                ),
                encoding="utf-8",
            )
            output = {"ok": True, "output": str(args.output)}
        else:  # pragma: no cover
            raise ValidationError(f"unsupported command {args.command}")
    except (OSError, ValidationError, validate_verdict_report.ValidationError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(output, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
