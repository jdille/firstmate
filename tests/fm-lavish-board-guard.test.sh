#!/usr/bin/env bash
# Behavioral coverage for bin/fm-lavish-board-guard.sh: which crew-hosted Lavish
# boards read as unattended, and how often that is reported.
#
# Attendance is proved with REAL processes. Each "live poll" case starts a
# genuine `lavish-axi poll <file>` from the fixture's PATH stub and lets the
# guard find it in the real process table, because the whole point of the check
# is that the operating system, not a registration, is what knows whether
# anything is listening to a board.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-lavish-board-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-lavish-board-guard)

POLLERS=()

cleanup_pollers() {
  local pid
  for pid in ${POLLERS+"${POLLERS[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  POLLERS=()
}

trap 'cleanup_pollers; fm_test_cleanup' EXIT
trap 'cleanup_pollers; fm_test_cleanup; exit 130' INT
trap 'cleanup_pollers; fm_test_cleanup; exit 143' TERM

BOARD_URL='http://127.0.0.1:4387/session/deadbeefcafe0001'
OTHER_URL='http://127.0.0.1:4387/session/deadbeefcafe0002'

# A world is one firstmate home plus a PATH stub pair: a `lavish-axi` whose only
# real behavior is a blocking `poll` (so a live listener is a live process), and
# a `tmux` whose pane lookup succeeds only while the task's endpoint marker
# exists (so endpoint liveness is a fixture switch, not a timing artifact).
make_world() { # <name>
  WORLD="$TMP_ROOT/$1"
  HOME_DIR="$WORLD/home"
  FAKEBIN="$WORLD/fakebin"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$FAKEBIN" "$WORLD/boards"
  BOARD_FILE="$WORLD/boards/board.html"
  : > "$BOARD_FILE"
  SESSIONS_FILE="$WORLD/sessions.txt"
  printf 'open\t%s\t%s\n' "$BOARD_URL" "$BOARD_FILE" > "$SESSIONS_FILE"

  cat > "$FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1-}" in
  poll)
    # A real blocking listener, bounded so an escaped process cannot outlive
    # the suite by more than its cap.
    limit=${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}
    while [ ! -e "${LAVISH_STUB_STOP:?}" ]; do
      [ "$SECONDS" -lt "$limit" ] || exit 75
      sleep 0.05
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/lavish-axi"

  # The adapter's read-only session listing, stubbed at the guard's seam so the
  # case controls what the server reports without reaching a real server.
  cat > "$FAKEBIN/fm-lavish-sessions.sh" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1-}" = sessions ] || exit 2
[ -z "${LAVISH_SESSIONS_FAIL:-}" ] || exit 1
cat "${LAVISH_SESSIONS_FILE:?}"
SH
  chmod +x "$FAKEBIN/fm-lavish-sessions.sh"

  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1-}" in
  display-message)
    [ -e "${TMUX_STUB_ENDPOINT:?}" ] || exit 1
    printf '%%1\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/tmux"

  ENDPOINT_MARKER="$WORLD/endpoint-alive"
  : > "$ENDPOINT_MARKER"
  STOP_MARKER="$WORLD/poll-stop"
}

write_task() { # <id> <status-line>...
  local id=$1
  shift
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$WORLD/wt-$id" 'project=alpha' \
    'harness=codex' 'kind=scout'
  : > "$HOME_DIR/state/$id.status"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$HOME_DIR/state/$id.status"
  done
}

start_poll() { # <file>
  PATH="$FAKEBIN:$PATH" LAVISH_STUB_STOP="$STOP_MARKER" \
    lavish-axi poll "$1" >/dev/null 2>&1 &
  local pid=$!
  POLLERS+=("$pid")
  # Wait until the process table actually shows it, so no case races its own
  # fixture into a false "unattended" verdict.
  local waited=0
  while [ "$waited" -lt 200 ]; do
    if pgrep -f -- "lavish-axi poll $1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
    waited=$((waited + 1))
  done
  fail "the fixture poll for $1 never appeared in the process table"
}

run_scan() { # [grace-seconds]
  local grace=${1:-60}
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_LAVISH_BOARD_GRACE_SECS="$grace" \
    FM_LAVISH_SESSIONS_BIN="$FAKEBIN/fm-lavish-sessions.sh" \
    LAVISH_SESSIONS_FILE="$SESSIONS_FILE" \
    TMUX_STUB_ENDPOINT="$ENDPOINT_MARKER" \
    "$GUARD" scan
}

queued_board_wakes() {
  local n
  n=$(grep -c 'lavish-board-unattended:' "$HOME_DIR/state/.wake-queue" 2>/dev/null || true)
  printf '%s\n' "${n:-0}"
}

age_record() { # <seconds-ago>
  local record ago=$1 now
  now=$(date +%s)
  for record in "$HOME_DIR/state/".lavish-board-unattended-*; do
    [ -f "$record" ] || continue
    sed -i.bak "s/^first_unattended=.*/first_unattended=$((now - ago))/" "$record"
    rm -f "$record.bak"
  done
}

# A home whose status logs name no board never reports one, and never needs the
# Lavish server at all.
test_no_board_is_silent() {
  make_world no-board
  write_task alpha 'working: building the thing' 'done: PR https://example.test/owner/repo/pull/1'
  rm -f "$FAKEBIN/fm-lavish-sessions.sh"
  local out
  out=$(run_scan) || fail "scan failed on a home with no board"
  [ -z "$out" ] || fail "a home with no board reported: $out"
  [ "$(queued_board_wakes)" = 0 ] || fail "a home with no board queued a wake"
  pass "fm-lavish-board-guard.sh: no board, no wake and no Lavish call"
}

# The board the captain is looking at has a live listener, so nothing is owed.
test_live_poll_is_attended() {
  make_world live-poll
  write_task alpha "needs-decision [key=board-review]: review the board at $BOARD_URL"
  start_poll "$BOARD_FILE"
  local out
  out=$(run_scan 60) || fail "scan failed with a live poll"
  [ -z "$out" ] || fail "an attended board was reported: $out"
  [ "$(queued_board_wakes)" = 0 ] || fail "an attended board queued a wake"
  pass "fm-lavish-board-guard.sh: a board with a live poll is attended"
}

# Nothing is polling and the grace period is spent: exactly one wake, carrying
# the task, the URL, and the file.
test_unattended_past_grace_reports_once() {
  make_world unattended
  write_task alpha "needs-decision [key=board-review]: review the board at $BOARD_URL"
  run_scan 60 >/dev/null || fail "the first scan failed"
  [ "$(queued_board_wakes)" = 0 ] || fail "a board inside its grace period was reported"
  age_record 600
  local out
  out=$(run_scan 60) || fail "the grace-expired scan failed"
  case "$out" in
    *"task=alpha"*) ;;
    *) fail "the wake did not name the task: $out" ;;
  esac
  case "$out" in
    *"url=$BOARD_URL"*) ;;
    *) fail "the wake did not carry the board URL: $out" ;;
  esac
  case "$out" in
    *"file=$BOARD_FILE"*) ;;
    *) fail "the wake did not carry the artifact file: $out" ;;
  esac
  [ "$(queued_board_wakes)" = 1 ] || fail "expected exactly one queued wake"
  pass "fm-lavish-board-guard.sh: an unattended board past grace reports once"
}

# The same still-unattended board on the next cycle stays quiet.
test_second_cycle_does_not_duplicate() {
  make_world no-duplicate
  write_task alpha "needs-decision [key=board-review]: review the board at $BOARD_URL"
  run_scan 60 >/dev/null || fail "the first scan failed"
  age_record 600
  run_scan 60 >/dev/null || fail "the reporting scan failed"
  [ "$(queued_board_wakes)" = 1 ] || fail "the reporting scan did not queue one wake"
  # Drain the queue so a second wake would be visible as a new row rather than
  # suppressed by the queue itself: the record's own marker must carry it.
  : > "$HOME_DIR/state/.wake-queue"
  local out
  out=$(run_scan 60) || fail "the repeat scan failed"
  [ -z "$out" ] || fail "the same unattended board reported twice: $out"
  [ "$(queued_board_wakes)" = 0 ] || fail "the same unattended board queued a second wake"
  pass "fm-lavish-board-guard.sh: a still-unattended board is not reported twice"
}

# A task whose endpoint is gone has no worker to re-ring, so its board is not
# this check's business.
test_dead_task_is_not_reported() {
  make_world dead-task
  write_task alpha "needs-decision [key=board-review]: review the board at $BOARD_URL"
  rm -f "$ENDPOINT_MARKER"
  local out
  out=$(run_scan 60) || fail "scan failed on a dead task"
  [ -z "$out" ] || fail "a dead task's board was reported: $out"
  age_record 600 2>/dev/null || true
  out=$(run_scan 60) || fail "the second dead-task scan failed"
  [ -z "$out" ] || fail "a dead task's board was reported on a later cycle: $out"
  [ "$(queued_board_wakes)" = 0 ] || fail "a dead task's board queued a wake"
  pass "fm-lavish-board-guard.sh: a dead task's board is never reported"
}

# A URL the log has already moved past, and a session the server no longer
# lists as open, are both out of scope.
test_superseded_and_closed_boards_are_skipped() {
  make_world superseded
  write_task alpha \
    "needs-decision [key=board-review]: review the board at $BOARD_URL" \
    'working: captain answered, carrying on' \
    'done: report written'
  # The URL now sits only in a terminal line the log has moved past.
  local out
  out=$(run_scan 60) || fail "scan failed on a superseded board line"
  [ -z "$out" ] || fail "a superseded board line was reported: $out"

  make_world closed-session
  write_task alpha "needs-decision [key=board-review]: review the board at $BOARD_URL"
  printf 'user-ended\t%s\t%s\n' "$BOARD_URL" "$BOARD_FILE" > "$SESSIONS_FILE"
  run_scan 60 >/dev/null || fail "scan failed on a closed session"
  age_record 600 2>/dev/null || true
  out=$(run_scan 60) || fail "the second closed-session scan failed"
  [ -z "$out" ] || fail "a session the server no longer holds open was reported: $out"

  make_world unlisted-session
  write_task alpha "needs-decision [key=board-review]: review the board at $OTHER_URL"
  out=$(run_scan 60) || fail "scan failed on an unlisted session"
  [ -z "$out" ] || fail "a session the server does not list was reported: $out"
  pass "fm-lavish-board-guard.sh: superseded, closed, and unlisted boards are skipped"
}

# A board that regains a listener clears its record, so a later lapse rings
# again instead of being permanently suppressed.
test_attention_clears_the_record_and_a_later_lapse_rings() {
  make_world relapse
  write_task alpha "needs-decision [key=board-review]: review the board at $BOARD_URL"
  run_scan 60 >/dev/null || fail "the first scan failed"
  age_record 600
  run_scan 60 >/dev/null || fail "the reporting scan failed"
  [ "$(queued_board_wakes)" = 1 ] || fail "the reporting scan did not queue one wake"
  start_poll "$BOARD_FILE"
  run_scan 60 >/dev/null || fail "the attended scan failed"
  local record found=0
  for record in "$HOME_DIR/state/".lavish-board-unattended-*; do
    [ -f "$record" ] && found=1
  done
  [ "$found" = 0 ] || fail "an attended board kept its unattended record"
  : > "$STOP_MARKER"
  cleanup_pollers
  local waited=0
  while pgrep -f -- "lavish-axi poll $BOARD_FILE" >/dev/null 2>&1; do
    waited=$((waited + 1))
    [ "$waited" -lt 200 ] || fail "the fixture poll never exited"
    sleep 0.05
  done
  : > "$HOME_DIR/state/.wake-queue"
  run_scan 60 >/dev/null || fail "the relapse scan failed"
  age_record 600
  run_scan 60 >/dev/null || fail "the relapse reporting scan failed"
  [ "$(queued_board_wakes)" = 1 ] || fail "a later lapse did not ring again"
  pass "fm-lavish-board-guard.sh: attention clears the record and a later lapse rings"
}

# An unreadable session listing changes nothing: no wake, no pruning, and a
# non-zero exit so the caller reports the scan rather than trusting it.
test_unreadable_listing_refuses_rather_than_guessing() {
  make_world listing-fails
  write_task alpha "needs-decision [key=board-review]: review the board at $BOARD_URL"
  local rc=0 out
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_LAVISH_BOARD_GRACE_SECS=60 \
    FM_LAVISH_SESSIONS_BIN="$FAKEBIN/fm-lavish-sessions.sh" \
    LAVISH_SESSIONS_FILE="$SESSIONS_FILE" LAVISH_SESSIONS_FAIL=1 \
    TMUX_STUB_ENDPOINT="$ENDPOINT_MARKER" \
    "$GUARD" scan 2>/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable session listing reported success"
  [ -z "$out" ] || fail "an unreadable session listing still reported a board: $out"
  [ "$(queued_board_wakes)" = 0 ] || fail "an unreadable session listing queued a wake"
  pass "fm-lavish-board-guard.sh: an unreadable session listing refuses"
}

test_no_board_is_silent
test_live_poll_is_attended
test_unattended_past_grace_reports_once
test_second_cycle_does_not_duplicate
test_dead_task_is_not_reported
test_superseded_and_closed_boards_are_skipped
test_attention_clears_the_record_and_a_later_lapse_rings
test_unreadable_listing_refuses_rather_than_guessing

echo "all lavish board guard tests passed"
