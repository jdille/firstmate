#!/usr/bin/env bash
# fm-lavish-board-guard.sh - detect a crew-hosted Lavish review board that
# nothing is listening to.
#
# Usage:
#   fm-lavish-board-guard.sh scan
#
# THE DEFECT THIS EXISTS FOR. A worker publishes a Lavish board, posts its URL
# in a status line, and then moves on without keeping `lavish-axi poll` running.
# The board stays open, the captain annotates it, the browser shows "Your agent
# is not listening", and every comment sits queued on the server. Nothing errors
# and nothing is lost - the feedback simply never reaches firstmate, so the only
# way the captain found out was by saying so in chat. The brief scaffold in
# bin/fm-brief.sh tells a worker to start that poll before it writes any status
# line about the board; this scan is what notices when one did not.
#
# WHAT IT DOES NOT DO. It never arms, polls, opens, resumes, or ends a board.
# docs/configuration.md "Crew-hosted Lavish review boards" is the owner of that
# boundary: the hosting task owns its listener, so the only correct response to
# an unattended board is to re-ring that worker, or - once its claim is proved
# dead - to take the existing guarded adoption path. This scan detects and
# reports; firstmate decides.
#
# THE FOUR GATES, all of which must hold before one wake is published.
#   1. A board URL (http://<host>:<port>/session/<id>) appears in this home's
#      state/<id>.status log, in a line that is either NOT terminal by
#      bin/fm-classify-lib.sh's status_is_terminal_verb contract or is the
#      log's last line. A URL whose only mentions are terminal lines the log
#      has already moved past belongs to a finished phase.
#   2. The task is live: its recorded endpoint still exists, read through
#      bin/fm-backend.sh's cheap read-only fm_backend_target_exists. A torn-down
#      or dead task has no worker to re-ring.
#   3. The Lavish server still lists that URL with status `open`, resolved to
#      its artifact file by bin/fm-procevent-lavish.sh's read-only `sessions`
#      command, which owns every lavish-axi invocation here.
#   4. No process is polling that artifact - no `lavish-axi poll <file>` and no
#      `fm-procevent-lavish.sh poll <file>` in the process table - and that has
#      been observably true for longer than the grace period below.
#
# The process table is the attendance source because it is the one signal that
# covers both listeners a board can legitimately have: a worker's own foreground
# poll, which is registered nowhere, and the process-event runner's child. A
# registration record would miss the first entirely.
#
# GRACE AND DEDUPLICATION. A worker between poll rounds - reading feedback,
# rebuilding the artifact, polling again - is briefly unattended and is not a
# defect. The grace period is measured from the first cycle that OBSERVED the
# board unattended, recorded in state/.lavish-board-unattended-<hash>, and the
# same record carries the once-per-episode notified flag, so a board that stays
# unattended produces exactly one wake rather than one per watcher poll. The
# record is removed the moment the board is attended again, closes, or its task
# goes away, so a later lapse rings again. FM_LAVISH_BOARD_GRACE_SECS overrides
# the default (300), bounded to 60..3600.
#
# OUTPUT AND EXIT. One `actionable: <payload>` line per newly reported board on
# stdout, nothing on a quiet scan. Exit 0 when the scan completed, 1 when it
# could not (the caller reports that and changes nothing). A home whose status
# logs mention no board URL never invokes lavish-axi and never reads the process
# table at all, so a fleet with no boards pays one directory read per call. The
# CALLER owns how often to call: bin/fm-watch.sh runs this on its own interval
# rather than every 15-second cycle, and the grace period is wall-clock from the
# first observation, so a slower cadence cannot delay the report.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

RECORD_PREFIX=".lavish-board-unattended-"
SESSIONS_BIN="${FM_LAVISH_SESSIONS_BIN:-$SCRIPT_DIR/fm-procevent-lavish.sh}"
# Bounds on the two external reads. Neither is expected to block; the bound is
# there so a wedged server or process table cannot stall a watcher cycle.
SESSIONS_TIMEOUT=${FM_LAVISH_SESSIONS_TIMEOUT:-15}
PS_TIMEOUT=${FM_LAVISH_PS_TIMEOUT:-15}

GRACE_SECS=${FM_LAVISH_BOARD_GRACE_SECS:-300}
case "$GRACE_SECS" in
  ''|*[!0-9]*)
    printf 'fm-lavish-board-guard: FM_LAVISH_BOARD_GRACE_SECS must be a whole number from 60 to 3600\n' >&2
    exit 2
    ;;
esac
if [ "$GRACE_SECS" -lt 60 ] || [ "$GRACE_SECS" -gt 3600 ]; then
  printf 'fm-lavish-board-guard: FM_LAVISH_BOARD_GRACE_SECS must be a whole number from 60 to 3600\n' >&2
  exit 2
fi

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

valid_id() {  # <task-id>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    .|..) return 1 ;;
  esac
  return 0
}

board_hash() {  # <task-id> <artifact-file>
  local payload
  payload=$(printf '%s\t%s' "$1" "$2")
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$payload" | shasum -a 256 | awk '{print substr($1,1,32)}'
  else
    printf '%s' "$payload" | sha256sum | awk '{print substr($1,1,32)}'
  fi
}

record_value() {  # <record> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# Board URLs a task's status log still stands behind. Gate 1 above owns the
# rule; this is its only implementation.
status_board_urls() {  # <status-file>
  local status=$1
  [ -f "$status" ] && [ ! -L "$status" ] || return 0
  local line last=""
  while IFS= read -r line || [ -n "$line" ]; do
    last=$line
  done < "$status"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if status_is_terminal_verb "$line" && [ "$line" != "$last" ]; then
      continue
    fi
    printf '%s\n' "$line" | grep -Eo 'https?://[A-Za-z0-9.:_-]+/session/[A-Za-z0-9_-]+' || true
  done < "$status"
}

# Gate 2: the recorded endpoint still exists. An unreadable or absent endpoint
# reads as not live, which is the conservative answer here - a task with no
# worker to re-ring is not the defect this scan reports.
task_endpoint_live() {  # <meta-file>
  local meta=$1 backend target window
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] || return 1
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  fm_backend_target_exists "$backend" "${target:-$window}" "fm-$(basename "$meta" .meta)"
}

# Gate 4: is anything polling this artifact right now?
board_attended() {  # <artifact-file> <ps-snapshot>
  perl -e '
    use strict;
    use warnings;
    my ($file) = @ARGV;
    while (my $line = <STDIN>) {
      next unless $line =~ m{(?:^|/)(?:lavish-axi|fm-procevent-lavish\.sh)(?:\s|$)};
      next unless $line =~ /(?:^|\s)poll(?:\s|$)/;
      next unless $line =~ /(?:^|\s)\Q$file\E(?:\s|$)/;
      exit 0;
    }
    exit 1;
  ' "$1" < "$2"
}

process_snapshot() {  # <destination>
  local dest=$1
  if fm_run_timed "$PS_TIMEOUT" ps -eww -o args= > "$dest" 2>/dev/null; then
    return 0
  fi
  fm_run_timed "$PS_TIMEOUT" ps -eo args= > "$dest" 2>/dev/null
}

queue_key_exists() {  # <key>
  fm_wake_queued_keys check 2>/dev/null | grep -Fx -- "$1" >/dev/null 2>&1
}

# One durable check wake, published through the ordinary queue so it survives a
# watcher restart and is drained like every other wake.
publish_board_wake() {  # <task> <url> <file> <unattended-secs> <hash>
  local task=$1 url=$2 file=$3 age=$4 hash=$5 key payload
  key="lavish-board-unattended:$task:$hash"
  payload="lavish board unattended: task=$task url=$url file=$file unattended_for=${age}s"
  if ! queue_key_exists "$key"; then
    fm_wake_append check "$key" "$payload" || return 1
  fi
  printf 'actionable: %s\n' "$payload"
}

scan() {
  [ -d "$STATE" ] || return 0
  local meta id status url urls candidates="" seen_pair=""
  # Gate 1, over every direct task record in this home.
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
    status="$STATE/$id.status"
    urls=$(status_board_urls "$status") || continue
    [ -n "$urls" ] || continue
    # Gate 2, paid once, and only for a task that actually named a board.
    task_endpoint_live "$meta" || continue
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      case "$seen_pair" in *"|$id $url|"*) continue ;; esac
      seen_pair="$seen_pair|$id $url|"
      candidates="$candidates$id $url"$'\n'
    done <<EOF
$urls
EOF
  done

  if [ -z "$candidates" ]; then
    prune_records ""
    return 0
  fi

  # Gate 3: one listing for the whole scan.
  local listing
  listing=$(fm_run_timed "$SESSIONS_TIMEOUT" env FM_HOME="$FM_HOME" \
    "$SESSIONS_BIN" sessions 2>/dev/null) || {
    printf 'fm-lavish-board-guard: the Lavish session listing could not be read\n' >&2
    return 1
  }

  local snapshot snapshot_ok=0 cleanup_command
  snapshot=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-ps.XXXXXX") || return 1
  printf -v cleanup_command 'rm -f -- %q' "$snapshot"
  # shellcheck disable=SC2064 # $cleanup_command must expand now, while the staged path is still set.
  trap "$cleanup_command" EXIT
  process_snapshot "$snapshot" && snapshot_ok=1
  if [ "$snapshot_ok" -ne 1 ]; then
    printf 'fm-lavish-board-guard: the process table could not be read\n' >&2
    return 1
  fi

  local pair task file lstatus lurl lfile hash record now first age rc=0 keep=""
  now=$(date +%s)
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    task=${pair%% *}
    url=${pair#* }
    file=""
    while IFS=$(printf '\t') read -r lstatus lurl lfile; do
      [ "$lurl" = "$url" ] || continue
      [ "$lstatus" = open ] || continue
      file=$lfile
      break
    done <<EOF
$listing
EOF
    [ -n "$file" ] || continue
    hash=$(board_hash "$task" "$file") || continue
    record="$STATE/$RECORD_PREFIX$hash"
    if board_attended "$file" "$snapshot"; then
      rm -f -- "$record"
      continue
    fi
    keep="$keep|$hash|"
    if [ -f "$record" ] && [ ! -L "$record" ]; then
      first=$(record_value "$record" first_unattended)
    else
      first=""
    fi
    case "$first" in
      ''|*[!0-9]*)
        first=$now
        write_record "$record" "$task" "$url" "$file" "$first" 0 || rc=1
        ;;
    esac
    [ "$now" -ge "$first" ] || first=$now
    age=$((now - first))
    [ "$age" -ge "$GRACE_SECS" ] || continue
    [ "$(record_value "$record" notified)" != 1 ] || continue
    publish_board_wake "$task" "$url" "$file" "$age" "$hash" || { rc=1; continue; }
    write_record "$record" "$task" "$url" "$file" "$first" 1 || rc=1
  done <<EOF
$candidates
EOF
  prune_records "$keep"
  return "$rc"
}

write_record() {  # <record> <task> <url> <file> <first-epoch> <notified>
  local record=$1 tmp
  tmp=$(mktemp "$STATE/.lavish-board-unattended.XXXXXX") || return 1
  {
    printf 'schema=fm-lavish-board-unattended.v1\n'
    printf 'task=%s\n' "$2"
    printf 'url=%s\n' "$3"
    printf 'file=%s\n' "$4"
    printf 'first_unattended=%s\n' "$5"
    printf 'notified=%s\n' "$6"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$record" || { rm -f -- "$tmp"; return 1; }
}

# Records for boards this scan no longer considers unattended. Only this
# script's own namespace is ever touched.
prune_records() {  # <keep-list>
  local keep=$1 record hash
  for record in "$STATE/$RECORD_PREFIX"*; do
    [ -f "$record" ] || continue
    hash=$(basename "$record")
    hash=${hash#"$RECORD_PREFIX"}
    case "$keep" in *"|$hash|"*) continue ;; esac
    rm -f -- "$record"
  done
}

case "${1-}" in
  scan) shift; [ "$#" -eq 0 ] || usage; scan ;;
  ''|-h|--help|help) usage ;;
  *) printf 'fm-lavish-board-guard: unknown command: %s\n' "$1" >&2; exit 2 ;;
esac
