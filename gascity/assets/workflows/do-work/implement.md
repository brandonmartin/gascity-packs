
Resolve `<source-anchor-id>` using the same rules as `prepare-worktree`. Read `work_dir` from the source anchor, validate that it is an absolute existing git
worktree, set `WORKTREE` to that path, then `cd "$WORKTREE"` before reading or
editing source files. If `work_dir` is missing, invalid, or points at the
launcher checkout, fail this step before editing.

Do not edit files in the launcher checkout. Implement only the owned source
anchor boundary, run sandboxed verification from inside the worktree, and make a
focused commit in the worktree. Leave the source anchor open for
`close-source-anchor`; close only this implementation step when done.

Write or update the task summary with these starter factory evidence fields:

- intended behavior
- first verification command
- changed files
- proof command
- remaining risks

Write the summary as a `gc.build.implementation-summary.v1` artifact and record
its absolute path on the workflow root bead as `gc.implementation.summary_path`
before closing.

Artifact validation: this step is gated by `.gc/scripts/checks/build-artifact-valid.sh`, which validates the summary recorded at `gc.implementation.summary_path` (fallbacks `gc.build.implementation_summary_path`, then `gc.var.summary_path`) against schema `gc.build.implementation-summary.v1`. On repair attempts (`gc.attempt` greater than 1), read the validator errors from `gc.attempt_log` on the validation loop control bead (the dependent of this step bead) and repair the summary in place instead of rewriting it. Two bounded repair attempts follow the first failure; exhausting them closes this stage with `gc.outcome=fail` and machine-readable validation errors that block downstream stages. Never ask questions in headless mode; record unresolved ambiguity inside the summary.
