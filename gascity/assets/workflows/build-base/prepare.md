This is the `build-base` prepare stage. Treat it as a virtual contract that concrete formulas may override.

Launch inputs:

- artifact_root: {{artifact_root}}
- context_path: {{context_path}}
- requirements_path: {{requirements_path}}
- plan_path: {{plan_path}}
- decomposition_path: {{decomposition_path}}
- drain_policy: {{drain_policy}}
- interaction_mode: {{interaction_mode}}
- review_mode: {{review_mode}}
- implementation_target: {{implementation_target}}
- planning_formula: {{planning_formula}}
- decomposition_formula: {{decomposition_formula}}
- implementation_formula: {{implementation_formula}}
- implementation_item_formula: {{implementation_item_formula}}
- code_review_formula: {{code_review_formula}}
- review_fix_formula: {{review_fix_formula}}
- max_iterations: {{max_iterations}}
- push: {{push}}
- open_pr: {{open_pr}}

Validate the target, artifact root, and optional context inputs. Record the normalized artifact paths on the workflow root bead so later stages can reuse them without inventing new locations.

Validate mode inputs against the methodology vocabulary before any stage runs:
`interaction_mode` must be `interactive`, `autonomous`, or `headless`;
`review_mode` must be `report`, `agent`, or `interactive`; `drain_policy` must
be `separate` or `same-session`. The running formula's
`[metadata.gc.methodology]` declares which of those values it supports. If a
requested value is outside the vocabulary or unsupported by the formula's
declared metadata, stop this workflow as blocked instead of starting work:
record `gc.build.status=blocked` and a machine-readable
`gc.blocked_reason` (for example `unsupported-interaction-mode:headless`) on
the workflow root, then close this step with `gc.outcome=fail` and
`gc.failure_class=methodology_incompatible`. In `headless` interaction mode,
never ask questions; treat missing required input as the same blocked outcome.

Record the selected methodology formulas as adapter inputs, not as behavior in
this virtual contract. Entrypoint adapters may launch those formulas explicitly;
concrete build formulas may instead override stage steps while preserving the
same artifact names and close semantics.

Persist the normalized values on the workflow root bead using `gc.var.<name>` for each launch input and `gc.build.<artifact>_path` for resolved artifact paths. If an optional path input is blank, derive it under the resolved artifact root and record the derived absolute path.

Resolved artifact path keys recorded on the workflow root are
`gc.build.requirements_path`, `gc.build.plan_path`,
`gc.build.decomposition_path`, `gc.build.implementation_summary_path`,
`gc.build.review_report_path`, and `gc.build.final_report_path`. Producer-stage
validation gates read these keys, so record every derived path even when the
matching launch input was blank.

When updating metadata, store plain scalar strings without embedded quote
characters. Prefer a single JSON-object update with `bd update <root> --metadata
'{"gc.var.push":"false","gc.var.open_pr":"false","gc.var.max_iterations":"10"}'`
or individually quoted `--set-metadata 'key=value'` arguments. Do not write
values like `"false"` or `"10"` that include literal double quotes.

Do not edit source files. Close this step only after the required paths and input assumptions are explicit.
