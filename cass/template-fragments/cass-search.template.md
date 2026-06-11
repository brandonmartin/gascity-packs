{{ define "cass-search" }}
## Session Search

When debugging, investigating prior failures, or entering an unfamiliar
subsystem, check past agent sessions before starting from scratch.

Use non-interactive `cass` commands only:

```bash
cass health --json || cass diag --json
cass sessions --current --json
cass sessions --workspace "$(pwd)" --json --limit 5
cass search "<query>" --json --limit 5 --fields minimal
```

Do not run `cass index`, `cass index --full`, or `cass doctor --fix` from an
agent session unless the human explicitly asks you to repair the shared CASS
store. Failed health means search may be unavailable; it is not permission to
start a rebuild.

If a hit looks relevant, inspect it with:

```bash
cass view <source_path> -n <line_number> --json
cass expand <source_path> -n <line_number> -C 3 --json
```

If you expect prior history but search returns nothing, verify ingestion
before assuming there is no precedent:

```bash
cass diag --json
```

Prefer a short, specific query first: an error string, workspace path,
subsystem name, or command.
{{ end }}
