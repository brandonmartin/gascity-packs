
Write the aggregate implementation summary, including selected anchors, drain
policy, item result classes, report paths, commit refs when available, and any
operator recovery instructions. Direct implement does not run gap-analysis or
review loops. Publish settings are push {{push}} and open_pr {{open_pr}}.

Write to summary_path {{summary_path}} when provided; otherwise use the default
implementation summary path for the workflow run. Update workflow root metadata
with `gc.implementation.summary_path=<absolute path>` so the optional publish
step has an explicit report path to consume. Write the summary as a
`gc.build.implementation-summary.v1` artifact.

Artifact validation: this step is gated by `.gc/scripts/checks/build-artifact-valid.sh`, which validates the summary recorded at `gc.implementation.summary_path` (fallback `gc.var.summary_path`) against schema `gc.build.implementation-summary.v1`. On repair attempts (`gc.attempt` greater than 1), read the validator errors from `gc.attempt_log` on the validation loop control bead (the dependent of this step bead) and repair the summary in place instead of rewriting it. Two bounded repair attempts follow the first failure; exhausting them closes this stage with `gc.outcome=fail` and machine-readable validation errors that block downstream stages. Never ask questions in headless mode; record unresolved ambiguity inside the summary.
