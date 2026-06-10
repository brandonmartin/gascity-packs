This is the `build-base` review stage. Treat it as a virtual contract that concrete formulas may override.

Review the implementation against the requirements, plan, decomposition, and
test evidence. Treat gap-analysis as one review lens inside this
post-implementation loop, not as a separate lifecycle stage. Findings must be
actionable and tied to concrete files, commands, or artifact paths.

Write the review report to the resolved review report path and record that path
on the workflow root bead as `gc.build.review_report_path` before closing.

Close this step only when the implementation is clean enough to finalize or when unresolved findings are recorded.

Artifact validation: this stage is gated by `.gc/scripts/checks/build-artifact-valid.sh`, which validates the artifact recorded at `gc.build.review_report_path` against schema `gc.build.review.v1`. On repair attempts (`gc.attempt` greater than 1), read the validator errors from `gc.attempt_log` on the validation loop control bead (the dependent of this step bead) and repair the artifact in place instead of rewriting it. Two bounded repair attempts follow the first failure; exhausting them closes this stage with `gc.outcome=fail` and machine-readable validation errors that block downstream stages. Never ask questions in headless mode; record unresolved ambiguity inside the artifact.
