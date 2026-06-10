This is the `planning-base` methodology contract preparation step.

Concrete methodology packs override this step to gather their native planning
context. Preserve the adapter-provided artifact paths and validate that
`{{artifact_root}}`, `{{context_path}}`, `{{requirements_path}}`, and
`{{plan_path}}` are plain paths before later planning steps write artifacts.
