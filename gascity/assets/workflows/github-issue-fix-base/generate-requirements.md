
Mechanically derive `requirements.md` from the issue body and triage report.
Mark the requirements artifact `status: approved` in both `interactive` and
`autonomous` modes. For `not_reproduced` plus `test_hardening`, state test
hardening explicitly and do not claim a confirmed bug fix. Current mode is
{{mode}}.

Read `gc.github.requirements_path` from workflow root metadata and write the
approved artifact to that absolute path. Do not choose or invent a different
path. If the metadata is missing or points outside the run directory, fail hard
instead of guessing a run directory.

Downstream implementation-plan, design-review, and create-beads steps must read
the artifact through `gc.github.requirements_path`.
