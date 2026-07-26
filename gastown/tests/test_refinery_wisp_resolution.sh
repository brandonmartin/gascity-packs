#!/usr/bin/env bash
# Guards the refinery patrol's current-wisp resolution.
#
# Patrol wisps are ephemeral beads, and `gc bd list` hides ephemeral beads
# unconditionally on bd 1.1.0 (there is no --include-ephemeral flag). A
# resolver built on `gc bd list --type=molecule` therefore matches nothing,
# every burn is skipped, and the loop leaks one wisp per iteration. The
# resolver has to go through `gc bd query 'ephemeral=true AND ...'`.
#
# Two halves:
#   structural — no ephemeral-blind resolver survives in the refinery's
#                formula or prompt, and every copy is identical
#   behavioral — the shipped snippet is extracted and executed against a
#                stubbed `gc`, proving what it actually resolves
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-refinery-patrol.toml"
PROMPT="$ROOT/gastown/agents/refinery/prompt.template.md"
MARKER="# resolve-current-wisp:"

# The refinery pours its next wisp *after* resolving the current one, so the
# newest matching wisp is always the live one. These counts pin the number of
# resolution sites: a new burn path must adopt the canonical block, not
# reintroduce an ad hoc query.
EXPECTED_FORMULA_SITES=5
EXPECTED_PROMPT_SITES=2

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# extract_block <file> <occurrence> — prints the Nth canonical resolver block,
# dedented to column 0 so it can be executed directly. Reads from the marker
# line to the outer `fi` at the marker's own indentation.
extract_block() {
    awk -v want="$2" -v marker="$MARKER" '
        !found && index($0, marker) {
            n++
            if (n == want) {
                match($0, /^[ \t]*/)
                ind = RLENGTH
                found = 1
            }
            next
        }
        found {
            body = substr($0, ind + 1)
            print body
            if (body == "fi") exit
        }
    ' "$1"
}

count_marker() { grep -c -F -- "$MARKER" "$1" || true; }

# ---------------------------------------------------------------- structural

# `gc bd list` filtered to in_progress molecules is the ephemeral-blind form
# that caused the leak. It must not survive on any refinery resolution path.
for f in "$FORMULA" "$PROMPT"; do
    if grep -n -- 'status=in_progress --type=molecule' "$f" >/dev/null 2>&1; then
        echo "--- offending lines ---" >&2
        grep -n -- 'status=in_progress --type=molecule' "$f" >&2
        fail "$(basename "$f") still resolves the current wisp with an ephemeral-blind 'gc bd list --type=molecule' query"
    fi
done

formula_sites=$(count_marker "$FORMULA")
prompt_sites=$(count_marker "$PROMPT")
[ "$formula_sites" -eq "$EXPECTED_FORMULA_SITES" ] \
    || fail "expected $EXPECTED_FORMULA_SITES resolver blocks in mol-refinery-patrol.toml, found $formula_sites"
[ "$prompt_sites" -eq "$EXPECTED_PROMPT_SITES" ] \
    || fail "expected $EXPECTED_PROMPT_SITES resolver blocks in the refinery prompt, found $prompt_sites"

# The bootstrap pour must land the wisp in the state the resolver queries for.
# a214d7e fixed the five `$NEXT` hand-offs but not this one, so a cold start left
# its first wisp `open` and the first burn could never resolve it.
bootstrap=$(grep -n -- 'gc bd update "$WISP" --assignee' "$PROMPT" || true)
[ -n "$bootstrap" ] || fail "could not find the bootstrap wisp assignment in the refinery prompt"
printf '%s\n' "$bootstrap" | while IFS= read -r line; do
    case "$line" in
        *--status=in_progress*) ;;
        *) echo "FAIL: bootstrap wisp assignment must set --status=in_progress: $line" >&2; exit 1 ;;
    esac
done || fail "bootstrap wisp is poured in a state the resolver cannot see"

# Every site must assign CURRENT_WISP through the canonical block — no site may
# keep a bespoke resolver alongside it.
assignments=$(grep -c -F -- 'CURRENT_WISP=${GC_BEAD_ID:-}' "$FORMULA" || true)
[ "$assignments" -eq "$EXPECTED_FORMULA_SITES" ] \
    || fail "mol-refinery-patrol.toml has $assignments CURRENT_WISP assignments but $EXPECTED_FORMULA_SITES resolver blocks"

# All copies identical after dedent — the copies drift silently otherwise.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

reference="$tmp/block-reference.sh"
extract_block "$FORMULA" 1 >"$reference"
[ -s "$reference" ] || fail "could not extract the canonical resolver block from mol-refinery-patrol.toml"
grep -q 'gc bd query' "$reference" \
    || fail "the canonical resolver block does not use 'gc bd query'"
grep -q "ephemeral=true" "$reference" \
    || fail "the canonical resolver block does not filter on ephemeral=true"

check_copies() {
    local file="$1" total="$2" i
    for i in $(seq 1 "$total"); do
        extract_block "$file" "$i" >"$tmp/block-$i.sh"
        diff -u "$reference" "$tmp/block-$i.sh" >"$tmp/diff.txt" 2>&1 \
            || { cat "$tmp/diff.txt" >&2; fail "resolver block #$i in $(basename "$file") differs from the canonical block"; }
    done
}
check_copies "$FORMULA" "$EXPECTED_FORMULA_SITES"
check_copies "$PROMPT" "$EXPECTED_PROMPT_SITES"

# ---------------------------------------------------------------- behavioral

BIN="$tmp/bin"
mkdir -p "$BIN"
cat >"$BIN/gc" <<'SH'
#!/usr/bin/env sh
# Only `gc bd query` is exercised. Record the call so tests can assert the
# query is skipped when GC_BEAD_ID already names the wisp.
case "$*" in
    *bd*query*)
        echo "$*" >>"$GC_QUERY_CALLS"
        cat "$GC_QUERY_JSON"
        ;;
    *) printf '[]' ;;
esac
SH
chmod +x "$BIN/gc"

QUERY_JSON="$tmp/query.json"
QUERY_CALLS="$tmp/calls.txt"

# resolve <fixture-json> [env assignments...] — runs the shipped block and
# prints the CURRENT_WISP it settled on.
resolve() {
    local payload="$1"
    shift
    printf '%s' "$payload" >"$QUERY_JSON"
    : >"$QUERY_CALLS"
    env PATH="$BIN:$PATH" \
        GC_QUERY_JSON="$QUERY_JSON" \
        GC_QUERY_CALLS="$QUERY_CALLS" \
        ${1+"$@"} \
        bash -c ". '$reference'; printf '%s' \"\${CURRENT_WISP:-}\""
}

wisp() {
    # wisp <id> <assignee> <title> <created_at>
    printf '{"id":"%s","assignee":"%s","title":"%s","status":"in_progress","ephemeral":true,"created_at":"%s"}' \
        "$1" "$2" "$3" "$4"
}

AGENT="gascity/gastown.refinery"
SESSION="gastown__refinery-th-abc12"

# 1. GC_BEAD_ID wins outright and costs no query.
got=$(resolve "[]" GC_BEAD_ID="ga-wisp-direct" GC_AGENT="$AGENT")
[ "$got" = "ga-wisp-direct" ] || fail "GC_BEAD_ID should resolve directly, got '$got'"
[ ! -s "$QUERY_CALLS" ] || fail "GC_BEAD_ID was set but the resolver still queried beads"

# 2. The regression itself: GC_BEAD_ID empty (the normal refinery session), one
#    live wisp assigned to $GC_AGENT. The old `gc bd list` resolver returned
#    nothing here and the burn was skipped.
one=$(wisp ga-wisp-mbpl "$AGENT" mol-refinery-patrol 2026-07-26T22:01:43Z)
got=$(resolve "[$one]" GC_BEAD_ID="" GC_AGENT="$AGENT")
[ "$got" = "ga-wisp-mbpl" ] || fail "wisp assigned to \$GC_AGENT should resolve with GC_BEAD_ID empty, got '$got'"
[ -s "$QUERY_CALLS" ] || fail "resolver never queried beads"
grep -q "ephemeral=true" "$QUERY_CALLS" || fail "resolver query did not ask for ephemeral beads"

# 3. Identity fallback: assigned to the runtime session name, not $GC_AGENT.
bysession=$(wisp ga-wisp-sess "$SESSION" mol-refinery-patrol 2026-07-26T22:01:43Z)
got=$(resolve "[$bysession]" GC_BEAD_ID="" GC_AGENT="$AGENT" GC_SESSION_NAME="$SESSION")
[ "$got" = "ga-wisp-sess" ] || fail "wisp assigned to \$GC_SESSION_NAME should resolve, got '$got'"

# 4. Leaked wisps from earlier iterations must not shadow the live one. The
#    block runs before the next wisp is poured, so newest == current.
older=$(wisp ga-wisp-old "$AGENT" mol-refinery-patrol 2026-07-26T20:00:00Z)
newer=$(wisp ga-wisp-new "$AGENT" mol-refinery-patrol 2026-07-26T22:30:00Z)
got=$(resolve "[$older,$newer]" GC_BEAD_ID="" GC_AGENT="$AGENT")
[ "$got" = "ga-wisp-new" ] || fail "expected the newest wisp, got '$got'"
got=$(resolve "[$newer,$older]" GC_BEAD_ID="" GC_AGENT="$AGENT")
[ "$got" = "ga-wisp-new" ] || fail "newest wisp must win regardless of result order, got '$got'"

# 5. Another formula's wisp on the same hook is not ours to burn.
foreign=$(wisp ga-wisp-deacon "$AGENT" mol-deacon-patrol 2026-07-26T22:30:00Z)
got=$(resolve "[$foreign]" GC_BEAD_ID="" GC_AGENT="$AGENT")
[ -z "$got" ] || fail "a mol-deacon-patrol wisp must not resolve as the refinery's wisp, got '$got'"

# 6. Someone else's wisp is never ours.
theirs=$(wisp ga-wisp-other "gascity/gastown.witness" mol-refinery-patrol 2026-07-26T22:30:00Z)
got=$(resolve "[$theirs]" GC_BEAD_ID="" GC_AGENT="$AGENT")
[ -z "$got" ] || fail "another agent's wisp must not resolve, got '$got'"

# 7. Nothing to resolve stays empty, so each caller's "could not resolve"
#    guard still fires instead of burning a wrong bead.
got=$(resolve "[]" GC_BEAD_ID="" GC_AGENT="$AGENT")
[ -z "$got" ] || fail "empty query result should leave CURRENT_WISP empty, got '$got'"

# 8. A wedged query (no output at all) must not resolve either.
got=$(resolve "" GC_BEAD_ID="" GC_AGENT="$AGENT")
[ -z "$got" ] || fail "unreadable query result should leave CURRENT_WISP empty, got '$got'"

# 9. Unset identity vars must not crash the block.
got=$(resolve "[$one]" GC_BEAD_ID="")
[ -z "$got" ] || fail "no identity in env should resolve nothing, got '$got'"

echo "PASS: refinery wisp resolution is ephemeral-aware at all $((formula_sites + prompt_sites)) sites"
