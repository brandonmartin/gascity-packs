#!/usr/bin/env bash
#
# deliver-rollup.sh — publish severity:escalate rollup beads to the
# operator's chat channel and mark them delivered. Idempotent.
#
# Routing model
# -------------
#
# Each rollup bead carries a ``rig:<name>`` label. The script delivers to
# that rig's own bound room first, falling back to a single city-wide
# room if the rig has no binding yet.
#
# Resolution order (per bead, in priority order):
#
#   1. Rig-specific room: the saved chat binding whose bound session is
#      ``<rig>/oversight-rig.project-lead``.
#   2. City-wide fallback: ``GC_OVERSIGHT_DISCORD_BINDING`` (a binding id
#      such as ``room:123...``), used when the rig has no binding or the
#      bead carries no rig label.
#
# WHY THIS USES `gc discord publish` AND NOT /extmsg/outbound (ga-0562)
# --------------------------------------------------------------------
#
# This script previously POSTed to ``/v0/city/{city}/extmsg/outbound``.
# On a Discord-wired city that path is DEAD, and it failed closed for
# every fire: severity:escalate rollups silently never reached the
# operator. Measured on thunderburg 2026-07-26:
#
#   GET /v0/city/{city}/extmsg/adapters              -> {"items":[],"total":0}
#   GET /v0/city/{city}/extmsg/bindings?session_id=* -> {"items":[],"total":0}
#   POST /v0/city/{city}/extmsg/outbound             -> 422 "no active binding
#                                                       for conversation discord/<id>"
#
# while ``gc discord status`` reported 9 healthy chat bindings and a
# successful publish through the very same room minutes earlier. The
# Discord pack keeps its own chat-binding registry and never populates
# extmsg, so BOTH the per-rig path and the old ``GC_OVERSIGHT_*``
# fallback were unreachable — the fallback hits the same endpoint and the
# same "no active binding" rejection, so it could not have rescued this.
#
# The old header claimed "the v0 SDK has no `gc extmsg send` command;
# outbound is HTTP-only". That is no longer true here: `gc discord
# publish --binding <id>` is documented for exactly this
# (operator-controlled sends) and is the path that demonstrably works.
#
# Restoring per-rig extmsg bindings so the original design works is
# tracked separately; this script deliberately targets the mechanism
# that is actually live.

set -euo pipefail

# NOTE: GC_API_BASE_URL / GC_CITY_NAME are intentionally NOT required
# any more. gc does not inject them into order exec (see
# slack-full/README.md:328) and thunderburg's city.toml has no
# [workspace].name to derive GC_CITY_NAME from, so the old
# `: "${VAR:?}"` guards aborted this script with exit 1 before it read a
# single bead — the first half of the ga-0562 outage.

# Discord rejects messages over 2000 characters, and does so SILENTLY on
# some paths, which would look like a successful delivery. Truncate well
# under the limit and say so in the message.
readonly DISCORD_MAX_BODY=1900

# resolve_binding <rig>
#
# Stdout: the saved chat binding id (e.g. "room:1524591982381367396").
# Returns 0 when a per-rig binding was found, 1 otherwise (caller falls
# back). Parses `gc discord status`, whose binding lines look like:
#   - room:152459... kind=room conversation=152459... sessions=gascity/oversight-rig.project-lead
resolve_binding() {
  local rig="$1"
  [[ -z "$rig" ]] && return 1
  local found
  found=$(gc discord status 2>/dev/null | awk -v want="sessions=${rig}/oversight-rig.project-lead" '
    $1 == "-" && $2 ~ /^room:/ && index($0, want) { print $2; exit }
  ')
  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
}

mapfile -t bead_ids < <(
  gc bd list --label rollup --label severity:escalate --status open --json \
    | jq -r '.[] | select((.labels // []) | index("delivered") | not) | .id'
)

if [[ ${#bead_ids[@]} -eq 0 ]]; then
  exit 0
fi

# City-wide fallback binding (e.g. "room:1524584813158465627"), used when
# a bead's rig has no binding of its own. If unset, such beads are left
# undelivered and retried next tick rather than silently disappearing.
fallback_binding="${GC_OVERSIGHT_DISCORD_BINDING:-}"

for id in "${bead_ids[@]}"; do
  bead_json=$(gc bd show "$id" --json)
  title=$(jq -r '.[0].title' <<<"$bead_json")
  body=$(jq -r '.[0].description // ""' <<<"$bead_json")
  rig=$(jq -r '.[0].labels[]? | select(startswith("rig:")) | sub("^rig:"; "")' <<<"$bead_json" | head -1)

  if binding=$(resolve_binding "$rig"); then
    target_label="rig:$rig"
  elif [[ -n "$fallback_binding" ]]; then
    binding="$fallback_binding"
    target_label="city-wide"
  else
    echo "deliver-rollup: rig=${rig:-<none>} has no chat binding and GC_OVERSIGHT_DISCORD_BINDING is unset; skipping bead $id" >&2
    continue
  fi

  text=$(printf '**%s**\n\n%s\n\n_(rollup bead %s · rig: %s)_\n_Reply here to respond to %s._' \
    "$title" "$body" "$id" "${rig:-<none>}" "$id")

  # Truncate rather than let Discord drop an over-long message on the
  # floor — a silent drop here is indistinguishable from a delivery and
  # would recreate the exact ga-0562 failure mode (operator sees nothing,
  # bead looks delivered). The bead id is in the text, so the operator can
  # always read the full rollup with `gc bd show`.
  if (( ${#text} > DISCORD_MAX_BODY )); then
    text="${text:0:DISCORD_MAX_BODY}"$'\n\n_[truncated — run `gc bd show '"$id"'` for the full rollup]_'
  fi

  # Deliver first, label second. If the publish succeeds but the label
  # write fails, the next tick re-delivers (a duplicate ping, which is
  # noisy but harmless). The reverse order could mark a bead delivered
  # that the operator never saw, which is the failure this bead is about.
  body_file=$(mktemp)
  printf '%s' "$text" >"$body_file"
  if gc discord publish --binding "$binding" --body-file "$body_file" >/dev/null 2>&1; then
    rm -f "$body_file"
    gc bd update "$id" --add-label delivered
    echo "delivered $id ($target_label, binding=$binding)"
  else
    rm -f "$body_file"
    echo "delivery failed for $id (binding=$binding); will retry next tick" >&2
  fi
done
