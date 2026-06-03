
Use the mayor implementation-plan procedure over the approved generated
requirements. In `interactive` mode, human-gate the implementation plan
artifact. In `autonomous` mode, generate and approve the implementation plan
non-interactively while recording the autonomous decision in the run artifacts.
Current mode is {{mode}}.

Read `gc.github.implementation_plan_path` from workflow root metadata and write
the approved artifact to that absolute path. Do not choose or invent a
different path. If the metadata is missing or points outside the run directory,
fail hard instead of guessing a run directory.

Downstream design-review and create-beads steps must read the artifact through
`gc.github.implementation_plan_path`. The legacy `gc.github.design_path` alias
is already set by `resume-or-create-run` and must point at this same file.
