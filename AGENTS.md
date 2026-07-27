# AGENTS.md — gascity-packs

Rules of engagement for agents working in this repo. Read the branching section
before you push anything.

## What this repo is

`gascity-packs` holds the pack definitions (`gastown/`, `discord/`,
`oversight-rig/`, `contributing/`, …) that a Gas City town imports. Note that
`contributing/` is a **pack**, not contributor documentation.

**This repo is live.** A town's `city.toml` path-imports the `gastown` and
`discord` packs directly from this working tree, so the checked-out branch is
what running agents actually execute. Editing a formula here changes agent
behavior on the next read — there is no separate deploy step to catch a mistake.

## Branching & merge — Rules of Engagement (READ FIRST)

This is a **fork**: `origin` is `github.com/brandonmartin/gascity-packs`,
`upstream` is `github.com/gastownhall/gascity-packs`. The refinery, polecats,
polekittens, and any automation MUST follow these rules — they are not optional.

Branch invariants:

```
upstream/main   source of truth
main            EXACTLY upstream/main — never ahead; sync by fast-forward only
develop         main + our unlanded work — this is what the town EXECUTES
```

1. **Never merge or push to the fork's `main`.** `origin/main` is a clean mirror
   of `upstream/main`; keep it pristine so upstream stays trivial to track.
   Merging or pushing work to `origin/main` is a defect — stop and use the
   correct branch instead.

   "But `main` is what the town executes" is **not** a justification. It is
   false (the town runs `develop`, see above) and it was the stated reasoning
   behind every prior violation of this rule.

2. **Land fork work on `develop`.** Create each change on a dedicated feature
   branch off `develop`, then merge it back to `develop`, never to `main`. The
   refinery merges to `develop`.

3. **Contribute upstream via a PR from a branch cut fresh off `upstream/main`**
   — one branch per PR, never cut from `main` or `develop`.

```bash
# fork-internal work
git fetch origin && git checkout -b feat/<topic> origin/develop
# … commit … then merge to develop (never to main)

# upstream contribution
git fetch upstream && git checkout -b pr/<topic> upstream/main   # FRESH off upstream/main
# … cherry-pick only this change's commits … then open the PR
```

Forbidden in all cases: any merge or push to `origin/main`.

### Hazard 1 — never rebase `develop`

`develop` is **shared**: the refinery merges into it and every polecat branches
from it. Rebasing rewrites its history and requires a force-push, which orphans
every in-flight polecat branch and breaks the refinery's merge bases.

- **DO:** `git merge main` (or `git merge upstream/main`) *into* `develop`.
- **DON'T:** rebase `develop` onto `main` as a standing practice.

Rebasing `develop` is permitted only during a full town quiesce, as a deliberate
one-off.

### Hazard 2 — never PR a branch cut from `develop`

A branch cut from `develop` carries all of `develop`'s other non-upstream
commits as ancestry, so a PR from it against `upstream/main` displays every one
of them — a stacked PR that cannot be reviewed or merged independently.

Per change: `git fetch upstream` → `git checkout -b pr/<topic> upstream/main`
(fresh) → cherry-pick only that change's commits → push to `origin` → open the
PR against `gastownhall/gascity-packs` `main`. One PR per change, no stacking.

### Upstream-PR checklist (run per PR)

- [ ] `main` fast-forwarded to `upstream/main` first
- [ ] branch cut fresh from `upstream/main`, **not** from `develop` (Hazard 2)
- [ ] `develop` was merged into, never rebased (Hazard 1)
- [ ] only this change's commits cherry-picked
- [ ] **checked for an open upstream PR touching the same files** — an open PR
      can supersede ours. Match on files touched, not on title.
- [ ] correct upstream: `gascity` and `gascity-packs` are **separate** upstreams
      with separate PR lists. Never quote a combined total; always name the repo.
- [ ] validated locally — upstream CI is not reliably green, so do not wait on it.

Cadence: batch the upstream PR sweep onto the binary-rebuild step, so "what we
deployed" and "what we upstreamed" stay in lockstep.

## Scope of this flow

This develop-then-upstream flow applies to **fork-type repos only**: `gascity`
and `gascity-packs`. Other repos in the city (`gc-packs`, `cashmaster`,
`scamper`, `champagne`, `daytripper`, `bigassets`, `docbook`) have no `upstream`
remote and stay on their own `main`/`master` — do not apply this flow to them.
