#!/usr/bin/env bash
#
# Tests for deliver-rollup.sh — the escalation delivery path.
#
# The defect under regression test (ga-7m69): an over-long rollup was cut at
# DISCORD_MAX_BODY from the END, which is exactly where the mandated
# `Smallest ask:` field lives. The operator got a P1 page with context and no
# ask, and the result was indistinguishable from a complete message.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/oversight-rig/assets/scripts/deliver-rollup.sh"

FALLBACK_BINDING="room:1524584813158465627"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# write_gc_stub <bin-dir>
#
# Stubs the four `gc` surfaces deliver-rollup.sh touches. `discord publish`
# copies the rendered body to $GC_STUB_PUBLISHED so assertions can inspect the
# exact bytes the operator would have received, and honours
# $GC_STUB_PUBLISH_EXIT so the failure path is testable.
write_gc_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/gc" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
"bd list")
    cat "$GC_STUB_LIST_JSON"
    ;;
"bd show")
    cat "$GC_STUB_SHOW_JSON"
    ;;
"bd update")
    printf '%s\n' "$*" >>"$GC_STUB_UPDATES"
    ;;
"discord status")
    # No per-rig binding in these tests; the city-wide fallback is used.
    printf ''
    ;;
"discord publish")
    while [ $# -gt 0 ]; do
        if [ "$1" = "--body-file" ]; then
            cat "$2" >"$GC_STUB_PUBLISHED"
            break
        fi
        shift
    done
    exit "${GC_STUB_PUBLISH_EXIT:-0}"
    ;;
*)
    printf ''
    ;;
esac
SH
    chmod +x "$bin/gc"
}

# make_body <filler-line-count> — a template-shaped rollup body whose LAST
# field is the mandated `Smallest ask:`, per the project-lead prompt template.
make_body() {
    local lines="$1" i
    printf 'Rig: gascity\nProject: Gas City\nState: blocked on a decision\n'
    printf 'Source bead(s): ga-0001\nStuck since: 2026-07-26T16:58:00Z\n'
    printf 'Why: *TL;DR:* the delivery path drops the ask.\n'
    for ((i = 0; i < lines; i++)); do
        printf '  - context bullet %02d: padding that exists only to overflow the Discord budget.\n' "$i"
    done
    printf '%s' "$SENTINEL_ASK"
}

SENTINEL_ASK='Smallest ask: Who files the beads-repo fix — mayor or oversight?'

# run_case <filler-line-count> — sets up a temp city, runs the real script, and
# leaves the rendered payload in $PAYLOAD plus the update log in $UPDATES.
run_case() {
    local lines="$1"
    local tmp bin
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    write_gc_stub "$bin"

    printf '[{"id":"ga-yhmk","labels":["rollup","severity:escalate","rig:gascity"]}]' \
        >"$tmp/list.json"

    # jq reads the description from real JSON, so build it with jq to get the
    # escaping right rather than hand-rolling it.
    make_body "$lines" >"$tmp/body.txt"
    jq -Rs '[{title: "Rollup(gascity): delivery drops the ask",
              description: .,
              labels: ["rollup", "severity:escalate", "rig:gascity"]}]' \
        <"$tmp/body.txt" >"$tmp/show.json"

    : >"$tmp/updates.log"
    : >"$tmp/published.txt"

    GC_STUB_LIST_JSON="$tmp/list.json" \
        GC_STUB_SHOW_JSON="$tmp/show.json" \
        GC_STUB_UPDATES="$tmp/updates.log" \
        GC_STUB_PUBLISHED="$tmp/published.txt" \
        GC_STUB_PUBLISH_EXIT="${PUBLISH_EXIT:-0}" \
        GC_OVERSIGHT_DISCORD_BINDING="$FALLBACK_BINDING" \
        PATH="$bin:$PATH" bash "$SCRIPT" >/dev/null

    PAYLOAD=$(cat "$tmp/published.txt")
    UPDATES=$(cat "$tmp/updates.log")
    BODY=$(cat "$tmp/body.txt")
    rm -rf "$tmp"
}

test_short_rollup_is_delivered_verbatim() {
    run_case 3

    [[ -n "$PAYLOAD" ]] || fail "nothing was published for an in-budget rollup"
    [[ "$PAYLOAD" == *"$SENTINEL_ASK"* ]] ||
        fail "in-budget rollup lost the Smallest ask line"
    [[ "$PAYLOAD" == *"context bullet 00"* && "$PAYLOAD" == *"context bullet 02"* ]] ||
        fail "in-budget rollup lost body context"
    [[ "$PAYLOAD" != *"trimmed"* ]] ||
        fail "in-budget rollup was marked as trimmed"
    [[ "$UPDATES" == *"--add-label delivered"* ]] ||
        fail "in-budget rollup was not labelled delivered"
}

test_oversized_rollup_preserves_the_smallest_ask() {
    run_case 40

    (( ${#BODY} > 1900 )) || fail "test fixture is not actually over budget (${#BODY})"
    [[ -n "$PAYLOAD" ]] || fail "nothing was published for an over-budget rollup"
    [[ "$PAYLOAD" == *"$SENTINEL_ASK"* ]] ||
        fail "over-budget rollup dropped the mandated Smallest ask field (ga-7m69)"
}

test_oversized_rollup_keeps_header_and_footer_intact() {
    run_case 40

    [[ "$PAYLOAD" == "**Rollup(gascity): delivery drops the ask**"* ]] ||
        fail "over-budget rollup lost its title header"
    [[ "$PAYLOAD" == *"_(rollup bead ga-yhmk · rig: gascity)_"* ]] ||
        fail "over-budget rollup lost the provenance footer"
    [[ "$PAYLOAD" == *"_Reply here to respond to ga-yhmk._" ]] ||
        fail "over-budget rollup lost the trailing reply affordance"
}

test_oversized_rollup_marks_the_trim_visibly() {
    run_case 40

    [[ "$PAYLOAD" == *"trimmed"* ]] ||
        fail "over-budget rollup was trimmed with no visible marker"
    [[ "$PAYLOAD" == *"ga-yhmk"* ]] ||
        fail "trim marker must name the bead so the full rollup is recoverable"
}

test_published_payload_stays_within_the_discord_budget() {
    run_case 40

    (( ${#PAYLOAD} <= 1900 )) ||
        fail "published payload is ${#PAYLOAD} chars, over the 1900 budget"
}

test_trim_seam_is_one_blank_line_on_each_side() {
    run_case 40

    [[ "$PAYLOAD" != *$'\n\n\n'* ]] ||
        fail "trim seam left a run of blank lines in the delivered message"
}

# The degenerate case elide_middle cannot fix from the body side: header and
# footer alone blow the budget. The final clamp must still keep the payload
# deliverable, and must keep the tail rather than the head.
test_absurd_title_still_produces_a_deliverable_payload() {
    local tmp bin title
    tmp=$(mktemp -d)
    bin="$tmp/bin"
    write_gc_stub "$bin"
    title=$(printf 'T%.0s' $(seq 1 2200))

    printf '[{"id":"ga-huge","labels":["rollup","severity:escalate","rig:gascity"]}]' \
        >"$tmp/list.json"
    make_body 3 >"$tmp/body.txt"
    jq -Rs --arg t "$title" \
        '[{title: $t, description: ., labels: ["rollup", "severity:escalate", "rig:gascity"]}]' \
        <"$tmp/body.txt" >"$tmp/show.json"
    : >"$tmp/updates.log"
    : >"$tmp/published.txt"

    GC_STUB_LIST_JSON="$tmp/list.json" \
        GC_STUB_SHOW_JSON="$tmp/show.json" \
        GC_STUB_UPDATES="$tmp/updates.log" \
        GC_STUB_PUBLISHED="$tmp/published.txt" \
        GC_OVERSIGHT_DISCORD_BINDING="$FALLBACK_BINDING" \
        PATH="$bin:$PATH" bash "$SCRIPT" >/dev/null

    local payload
    payload=$(cat "$tmp/published.txt")
    rm -rf "$tmp"

    (( ${#payload} <= 1900 )) ||
        fail "absurd-title payload is ${#payload} chars, over the 1900 budget"
    [[ "$payload" == *"_Reply here to respond to ga-huge._" ]] ||
        fail "absurd-title clamp cut the tail instead of the head"
}

test_failed_publish_is_not_labelled_delivered() {
    PUBLISH_EXIT=1 run_case 3

    [[ "$UPDATES" != *"--add-label delivered"* ]] ||
        fail "a failed publish was still labelled delivered"
}

test_short_rollup_is_delivered_verbatim
test_oversized_rollup_preserves_the_smallest_ask
test_oversized_rollup_keeps_header_and_footer_intact
test_oversized_rollup_marks_the_trim_visibly
test_published_payload_stays_within_the_discord_budget
test_trim_seam_is_one_blank_line_on_each_side
test_absurd_title_still_produces_a_deliverable_payload
test_failed_publish_is_not_labelled_delivered

echo "PASS: $(basename "${BASH_SOURCE[0]}")"
