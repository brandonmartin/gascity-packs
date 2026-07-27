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
#
# WHY OVERSIZED ROLLUPS ARE TRIMMED FROM THE MIDDLE (ga-7m69)
# -----------------------------------------------------------
#
# The length guard added with the ga-0562 fix cut the END of the message.
# The rollup template mandates field order and `Smallest ask:` is its LAST
# field, so for any rollup over the budget the delivery path deleted
# precisely the field that makes an escalation actionable: the operator was
# paged with context and no ask. Measured live on thunderburg 2026-07-26 —
# ga-yhmk (2076 chars) lost its ask, and ga-wk6k (2533 chars) lost its
# entire `*Asks:*` block, which is why that page sat unanswered for 6.5
# hours. There was nothing in it to answer.
#
# So the trim now spends overflow on CONTEXT instead of the ask: the title
# and the provenance/reply footer are always intact, and the body is elided
# from the middle, keeping its head and a larger tail. Preserving the tail
# is what preserves the ask — structurally, via the template's own field
# ordering, without this script having to know any field names. Every trim
# carries a visible marker stating how much was dropped, because a silent
# truncation that looks identical to a complete message is the failure mode
# both ga-0562 and ga-7m69 are about.

set -euo pipefail

# NOTE: GC_API_BASE_URL / GC_CITY_NAME are intentionally NOT required
# any more. gc does not inject them into order exec (see
# slack-full/README.md:328) and thunderburg's city.toml has no
# [workspace].name to derive GC_CITY_NAME from, so the old
# `: "${VAR:?}"` guards aborted this script with exit 1 before it read a
# single bead — the first half of the ga-0562 outage.

# Discord rejects messages over 2000 characters, and does so SILENTLY on
# some paths, which would look like a successful delivery. Stay well under
# the limit, and say so in the message whenever we trim.
readonly DISCORD_MAX_BODY=1900

# Share (percent) of the surviving body budget reserved for the body's TAIL
# when a rollup has to be trimmed. `Smallest ask:` is the template's last
# field, so the tail is the half that has to survive; the head is where
# overflow is spent (ga-7m69).
readonly ROLLUP_TAIL_SHARE=60

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

# trim_marker <out-var> <dropped-chars> <bead-id>
#
# The visible "something was removed here" marker. It names the bead so the
# operator can always recover the full rollup with `gc bd show`.
trim_marker() {
  local -n __marker_ref="$1"
  printf -v __marker_ref \
    '\n\n_[… %s characters of context trimmed — run `gc bd show %s` for the full rollup …]_\n\n' \
    "$2" "$3"
}

# elide_middle <out-var> <text> <budget> <bead-id>
#
# Fit <text> into <budget> characters. Text that already fits is passed
# through unchanged. Anything longer is cut from the MIDDLE, keeping a head
# and a larger tail (ROLLUP_TAIL_SHARE) joined by a visible marker, so the
# `Smallest ask:` field at the end of the body survives. See the ga-7m69
# note in the header.
elide_middle() {
  local -n __text_ref="$1"
  local text="$2" budget="$3" id="$4"
  local len=${#text}

  if (( len <= budget )); then
    __text_ref="$text"
    return 0
  fi

  # The marker costs budget, and its width depends on the dropped count,
  # which depends on the marker's width. Size it against `len` first — an
  # upper bound on the dropped count, so it can never have fewer digits than
  # the real value — then rebuild with the true count. The result lands at or
  # under budget, never over.
  local marker
  trim_marker marker "$len" "$id"
  local keep=$(( budget - ${#marker} ))

  if (( keep <= 0 )); then
    # Pathological: no room for head + marker + tail. The ask still wins —
    # keep the tail alone. `len > budget` is guaranteed above, so this offset
    # is always positive; a negative budget yields the empty string and the
    # caller's final clamp takes over.
    __text_ref="${text:len - budget}"
    return 0
  fi

  local tail_len=$(( keep * ROLLUP_TAIL_SHARE / 100 ))
  local head_len=$(( keep - tail_len ))
  local tail_start=$(( len - tail_len ))
  local head="${text:0:head_len}"
  local tail="${text:tail_start}"

  # Snap both cut points to line boundaries so neither fragment ends or
  # begins mid-sentence, then strip the newlines at the seam so the marker
  # supplies exactly one blank line on each side. Every step here only ever
  # shrinks what is kept, so the budget still holds.
  #
  # The snap also realigns both cuts onto an ASCII newline, which keeps the
  # slices from splitting a multi-byte character when this runs under a
  # non-UTF-8 locale (where ${#s} and ${s:i:n} count bytes). Rollup bodies
  # routinely carry `—`, `…` and `·`, and a half-written character is exactly
  # the kind of malformed payload a chat backend drops without telling us.
  local head_snap="${head%$'\n'*}"
  if [[ "$head_snap" != "$head" ]]; then
    head="$head_snap"
  fi
  local tail_snap="${tail#*$'\n'}"
  if [[ "$tail_snap" != "$tail" ]]; then
    tail="$tail_snap"
  fi
  while [[ "$head" == *$'\n' ]]; do head="${head%$'\n'}"; done
  while [[ "$tail" == $'\n'* ]]; do tail="${tail#$'\n'}"; done

  trim_marker marker "$(( len - ${#head} - ${#tail} ))" "$id"
  __text_ref="${head}${marker}${tail}"
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

  # Trim rather than let Discord drop an over-long message on the floor — a
  # silent drop is indistinguishable from a delivery and would recreate the
  # exact ga-0562 failure mode (operator sees nothing, bead looks delivered).
  # The header and footer are composed separately from the body so they are
  # never what gets cut: only the body is elided, and only in the middle.
  printf -v header '**%s**\n\n' "$title"
  printf -v footer '\n\n_(rollup bead %s · rig: %s)_\n_Reply here to respond to %s._' \
    "$id" "${rig:-<none>}" "$id"

  elide_middle trimmed_body "$body" \
    "$(( DISCORD_MAX_BODY - ${#header} - ${#footer} ))" "$id"
  text="${header}${trimmed_body}${footer}"

  # Final clamp. Only reachable if the header and footer alone blow the
  # budget (an absurdly long title), which elide_middle cannot fix from the
  # body side. Keep the tail for the same reason the body keeps its tail:
  # the ask and the reply affordance are the last things worth losing.
  if (( ${#text} > DISCORD_MAX_BODY )); then
    text="${text: -DISCORD_MAX_BODY}"
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
