#!/usr/bin/env bash
# tests/fm-lavish-board-guard-live-e2e.test.sh - live drift guard for the two
# vendor-emitted surfaces bin/fm-lavish-board-guard.sh reads.
#
# Why this file exists: the guard's verdict comes from things lavish-axi emits
# and the operating system reports, neither of which a stub can prove.
#   1. The session inventory `bin/fm-procevent-lavish.sh sessions` parses out of
#      bare `lavish-axi`, which is how a board URL - the only handle a status
#      log carries - resolves to its artifact file. That command refuses rather
#      than guesses when the published field order changes, so a vendor change
#      turns into a loud failure here instead of a board that is silently never
#      checked again.
#   2. The process-table shape of a real `lavish-axi poll`, which is how the
#      guard decides anybody is listening. A stub named lavish-axi proves only
#      that the stub matches; the installed tool runs its own node binary under
#      its own argv, and that is what must match.
#
# Standard CI has no lavish-axi, so this reports a capability skip there. The
# portable counterpart in tests/fm-lavish-board-guard.test.sh pins the guard's
# logic in CI with real processes and no Lavish server. Run this guard after a
# lavish-axi upgrade and before trusting refreshed evidence.
#
# Everything it touches is its own: a scratch artifact in a temporary directory
# and the one session it opens, which it ends again before returning. It never
# reads, ends, or polls a session it did not create.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate default-on FM_LAVISH_BOARD_LIVE lavish-axi

note() { printf '# %s\n' "$1"; }

LAB=''
POLL_PID=''
cleanup() {
  [ -z "$POLL_PID" ] || kill -TERM "$POLL_PID" 2>/dev/null || true
  [ -z "$LAB" ] || {
    [ ! -f "$LAB/board.html" ] \
      || lavish-axi end "$LAB/board.html" >/dev/null 2>&1 || true
    rm -rf "$LAB"
  }
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
trap cleanup EXIT

VERSION=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
note "lavish-axi ${VERSION:-version-unknown}"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lavish-board-live.XXXXXX") || fail "cannot create the guard lab"
LAB=$(cd -P -- "$LAB" && pwd -P)
mkdir -p "$LAB/state" "$LAB/data" "$LAB/fakebin"
BOARD="$LAB/board.html"
cat > "$BOARD" <<'HTML'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Board guard lab</title></head>
<body><h1>Board guard lab</h1><p>Scratch artifact for a live drift guard.</p></body></html>
HTML

# Endpoint liveness is the one thing this guard stubs: it is a tmux fact, not a
# Lavish one, and tests/fm-lavish-board-guard.test.sh already pins it.
cat > "$LAB/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1-}" in display-message) printf '%%1\n'; exit 0 ;; esac
exit 0
SH
chmod +x "$LAB/fakebin/tmux"

url=$(lavish-axi "$BOARD" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
case "$url" in
  http://*/session/*) ;;
  *) fail "could not open a guard lab session: $url" ;;
esac

# SURFACE 1: the published inventory still resolves this URL to this file.
listing=$("$ROOT/bin/fm-procevent-lavish.sh" sessions) \
  || fail "lavish-axi ${VERSION:-version-unknown} session listing could not be read; bin/fm-procevent-lavish.sh sessions must be revisited"
printf '%s\n' "$listing" | grep -Fq "$(printf 'open\t%s\t%s' "$url" "$BOARD")" \
  || fail "lavish-axi ${VERSION:-version-unknown} no longer resolves $url to $BOARD as an open session; bin/fm-procevent-lavish.sh sessions must be revisited"
pass "lavish-axi ${VERSION:-version-unknown} resolves a live board URL to its artifact file"

printf 'window=firstmate:fm-live\nworktree=%s\nproject=alpha\nharness=codex\nkind=scout\n' "$LAB/wt" \
  > "$LAB/state/live.meta"
printf 'needs-decision [key=board-review]: review the board at %s\n' "$url" \
  > "$LAB/state/live.status"

run_scan() {
  PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" \
    FM_LAVISH_BOARD_GRACE_SECS=60 "$ROOT/bin/fm-lavish-board-guard.sh" scan
}

age_record() {
  local record
  FM_LIVE_GUARD_EPOCH=$(( $(date +%s) - 600 ))
  export FM_LIVE_GUARD_EPOCH
  for record in "$LAB/state/".lavish-board-unattended-*; do
    [ -f "$record" ] || continue
    perl -i -pe 's/^first_unattended=.*/first_unattended=$ENV{FM_LIVE_GUARD_EPOCH}/' "$record"
  done
}

# SURFACE 2, attended half: a REAL lavish-axi poll on this board.
lavish-axi poll "$BOARD" >/dev/null 2>&1 &
POLL_PID=$!
waited=0
while [ "$waited" -lt 200 ]; do
  pgrep -f -- "poll $BOARD" >/dev/null 2>&1 && break
  sleep 0.05
  waited=$((waited + 1))
done
[ "$waited" -lt 200 ] || fail "the real lavish-axi poll never appeared in the process table"
out=$(run_scan) || fail "the scan failed while a real poll was listening"
[ -z "$out" ] || fail "a board with a REAL lavish-axi ${VERSION:-version-unknown} poll read as unattended: $out"
pass "a board with a real lavish-axi poll reads as attended"

# SURFACE 2, unattended half: the same board once that poll is gone.
kill -TERM "$POLL_PID" 2>/dev/null || true
wait "$POLL_PID" 2>/dev/null || true
POLL_PID=''
waited=0
while pgrep -f -- "poll $BOARD" >/dev/null 2>&1; do
  waited=$((waited + 1))
  [ "$waited" -lt 200 ] || fail "the real lavish-axi poll never left the process table"
  sleep 0.05
done
run_scan >/dev/null || fail "the first unattended scan failed"
age_record
out=$(run_scan) || fail "the grace-expired scan failed"
case "$out" in
  *"url=$url"*"file=$BOARD"*) ;;
  *) fail "a board with no listener was not reported: ${out:-<nothing>}" ;;
esac
grep -Fq 'lavish-board-unattended:live:' "$LAB/state/.wake-queue" \
  || fail "the unattended board queued no durable wake"
pass "the same board with no listener is reported once against real lavish-axi"

lavish-axi end "$BOARD" >/dev/null 2>&1 || true
echo "all live lavish board guard checks passed"
