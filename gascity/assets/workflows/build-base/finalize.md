This is the `build-base` finalize stage. Treat it as a virtual contract that concrete formulas may override.

Synthesize the workflow result from the requirements, plan, decomposition, implementation, and review artifacts. Record pass/fail outcome, artifact paths, and any remaining follow-up work.

Write the final build report to the resolved final report path and ensure that
path is recorded on the workflow root bead as `gc.build.final_report_path`.

Close this step only after the workflow root bead has the final outcome metadata needed by publish.

Artifact validation: this stage is gated by `.gc/scripts/checks/build-artifact-valid.sh`, which validates the artifact recorded at `gc.build.final_report_path` against schema `gc.build.final-report.v1`. On repair attempts (`gc.attempt` greater than 1), read the validator errors from `gc.attempt_log` on the validation loop control bead (the dependent of this step bead) and repair the artifact in place instead of rewriting it. Two bounded repair attempts follow the first failure; exhausting them closes this stage with `gc.outcome=fail` and machine-readable validation errors that block downstream stages. Never ask questions in headless mode; record unresolved ambiguity inside the artifact.
