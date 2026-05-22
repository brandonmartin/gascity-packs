# Gas City Planning Skills

This pack provides three manual planning skills and one implementation formula
for Gas City work:

- `gc.plan` gathers requirements and writes `requirements.md`.
- `gc.design` turns approved requirements into an engineering design.
- `gc.decompose` turns an approved design into an approved bead plan, then creates beads.
- `implement` routes the created bead DAG to workers, waits for completion,
  runs gap-analysis and review Ralph loops, commits the final state, and can
  optionally open a PR.

Import it with the `gascity` binding:

```toml
[imports.gascity]
source = "../gascity-packs/gascity"
```

Run the skills manually in order:

```text
Use skill gascity.plan
Use skill gascity.design
Use skill gascity.decompose
```

Then launch implementation from the target rig:

```sh
gc sling <coordinator-target> implement --formula \
  --var plan_slug=<plan-slug> \
  --var pack_root=/absolute/path/to/gc \
  --var worker_target=<worker-target>
```

`worker_target` may be empty when the target rig has a default sling target.
Set `open_pr=true` only when the workflow should push the branch and create a
PR after both Ralph loops pass.

By default artifacts go under the target rig:

```text
<rig-root>/.gc/plans/<plan-slug>/
  requirements.md
  design.md
  tasks.md
```

Each skill may use a different artifact root when the user explicitly asks for
one. The same `<plan-slug>/` structure should be used under the override root.

`gc.decompose` uses `scripts/create_beads_from_tasks.py` after approval. The
script requires Python 3 with PyYAML available, and invokes `gc bd --rig
<target_rig>` so beads are created in the intended rig store.

The `implement` formula uses `scripts/checks/*.sh` as Ralph convergence checks.
Pass `pack_root` explicitly so those scripts resolve from the imported pack
location instead of from any local checkout.
