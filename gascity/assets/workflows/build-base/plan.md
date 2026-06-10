This is the `build-base` plan stage. Treat it as a virtual contract that concrete formulas may override.

Use the requirements artifact and repository context to produce an implementation plan or design artifact. The artifact must identify affected areas, sequencing, risks, test strategy, and handoff criteria.

Close this step only after the plan path is recorded on the workflow root bead.

Artifact validation: this stage is gated by `.gc/scripts/checks/build-artifact-valid.sh`, which validates the artifact recorded at `gc.build.plan_path` (fallback `gc.var.plan_path`) against schema `gc.build.plan.v1`. On repair attempts (`gc.attempt` greater than 1), read the validator errors from `gc.attempt_log` on the validation loop control bead (the dependent of this step bead) and repair the artifact in place instead of rewriting it. Two bounded repair attempts follow the first failure; exhausting them closes this stage with `gc.outcome=fail` and machine-readable validation errors that block downstream stages. Never ask questions in headless mode; record unresolved ambiguity inside the artifact.
