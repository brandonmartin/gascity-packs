
Resume the latest active nonterminal issue-fix run by default. If no active run
exists, create one under
artifact-root-relative path
`/github/issues/<owner>/<repo>/<number>/fix/<run-id>/`, resolved with
`{{pack_root}}/assets/scripts/artifacts.py path --override "{{artifact_root}}"
--relative "/github/issues/<owner>/<repo>/<number>/fix/<run-id>/" --mkdir-parents
--directory`. If the issue body hash changed while a run is active, run/reuse
triage for the new hash and ask the human whether to continue the old run with
updated context or start fresh.

This step owns the issue-fix artifact path contract. Once the active run
directory is known, resolve these absolute paths under that run directory:

- `requirements.md`
- `implementation-plan.md`

Then publish all path metadata on the workflow root in one update:

```bash
bd update <root-bead-id> \
  --set-metadata gc.github.run_dir=<absolute run directory> \
  --set-metadata gc.github.requirements_path=<absolute requirements.md path> \
  --set-metadata gc.github.implementation_plan_path=<absolute implementation-plan.md path> \
  --set-metadata gc.github.design_path=<same absolute implementation-plan.md path>
```

`gc.github.design_path` is only a legacy alias for consumers that still use the
old key. It must point at the same file as `gc.github.implementation_plan_path`.
Do not schedule a separate design compatibility step and do not create
`design.md`.
