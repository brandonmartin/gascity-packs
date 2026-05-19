# GC Planning Skills

This pack provides three manual planning skills for Gas City work:

- `gc.plan` gathers requirements and writes `requirements.md`.
- `gc.design` turns approved requirements into an engineering design.
- `gc.decompose` turns an approved design into an approved bead plan, then creates beads.

Import it with the `gc` binding:

```toml
[imports.gc]
source = "../gascity-packs/gc"
```

Run the skills manually in order:

```text
Use skill gc.plan
Use skill gc.design
Use skill gc.decompose
```

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
