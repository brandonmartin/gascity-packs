This is the `build-base` requirements stage. Treat it as a virtual contract that concrete formulas may override.

Produce or reuse a requirements artifact under the build artifact root. The artifact must state the requested outcome, constraints, non-goals, acceptance criteria, and unresolved questions.

Close this step only after the requirements path is recorded on the workflow root bead.

Artifact validation: this stage is gated by `.gc/scripts/checks/build-artifact-valid.sh`, which validates the artifact recorded at `gc.build.requirements_path` (fallback `gc.var.requirements_path`) against schema `gc.build.requirements.v1`. On repair attempts (`gc.attempt` greater than 1), read the validator errors from `gc.attempt_log` on the validation loop control bead (the dependent of this step bead) and repair the artifact in place instead of rewriting it. Two bounded repair attempts follow the first failure; exhausting them closes this stage with `gc.outcome=fail` and machine-readable validation errors that block downstream stages. Never ask questions in headless mode; record unresolved ambiguity inside the artifact.
