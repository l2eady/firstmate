#!/usr/bin/env bash
# tests/fm-wake-daemon-lifecycle-e2e.test.sh - the watcher + supervise-daemon
# lifecycle, end to end, over one shared state root and a shimmed tmux:
#
#   routine status -> self-handled, queued
#   terminal status written while the watcher is DOWN -> caught on restart (catch-up)
#   drain queued records -> exactly ONE captain-relevant digest is buffered
#   housekeeping catch-all scan -> NO duplicate digest
#   buffered digest flushes to the supervisor pane as exactly ONE submission
#   stale working-pane: transient (self + marker) -> persistent (escalates once,
#     clears its marker) -> resumed/busy (clears without escalating)
#   turn-ended reconciliation: endpoint gone, endpoint idle, terminal done, and
#     a declared external pause
#
# This proves the operator-visible routing/queueing/dedupe behavior through real
# fm-watch.sh runs plus the daemon's own functions. The captain-relevant
# status-phrase matrix and the lock-primitive races stay as focused units
# (fm-daemon.test.sh, fm-watcher-lock.test.sh) - an e2e cannot deterministically
# cover a race, and the phrase list is a product contract worth a dedicated test.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

# Source the daemon's pure functions (its main loop is guarded out under sourcing).
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-wake-daemon-e2e)

# Run the daemon-managed watcher once: under the supervise-daemon (away mode) the
# watcher is one-shot - it exits with a single reason line on EVERY wake and the
# daemon does the triage. This e2e exercises exactly that path, so it runs with
# state/.afk present (which the daemon owns) to keep the watcher one-shot; the
# always-on standalone triage is covered by fm-watch-triage.test.sh. fakebin
# shadows tmux. Echoes nothing; the caller reads $out.
run_watcher_once() {
  local state=$1 fakebin=$2 out=$3
  mkdir -p "$state"
  date '+%s' > "$state/.afk"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 50
}

# --- Phase 1: routine self-handled, queued; terminal caught after restart ---
test_routine_then_terminal_after_restart() {
  local dir state fakebin out drain_out status_file
  dir=$(make_supercase wd-lifecycle)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  status_file="$state/task-w1.status"
  FM_CREW_STATE_BIN=$(make_fake_crew_state "$fakebin")
  export FM_CREW_STATE_BIN
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy · endpoint: alive'

  # A routine status fires a signal; the watcher queues it and exits.
  printf 'working: building\n' > "$status_file"
  run_watcher_once "$state" "$fakebin" "$out" || fail "watcher did not exit for the routine signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not report the routine signal"

  # Drain it and route through the daemon: a routine status self-handles.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after routine signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "routine signal was not queued"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $status_file" "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "routine status was escalated by the daemon"

  # The watcher is now DOWN (one-shot exit). A terminal status lands while it is
  # down; the next watcher run must catch it up (losslessness across restart).
  printf 'done: PR https://example.test/pr/900\n' >> "$status_file"
  : > "$out"
  run_watcher_once "$state" "$fakebin" "$out" || fail "restarted watcher did not exit for the terminal signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "terminal signal written while watcher down was not caught on restart"

  # Drain and route the terminal: exactly ONE digest is buffered.
  : > "$drain_out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after terminal signal failed"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $status_file" "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "captain-relevant terminal status was not buffered"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "expected exactly one buffered digest after the terminal signal"

  # The catch-all heartbeat scan must NOT re-escalate the same status (no dup).
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "catch-all scan duplicated the already-buffered digest"

  # With afk active, the buffered digest flushes to the supervisor pane as ONE
  # submission (one typed line + one Enter), then the buffer clears.
  local sent
  sent="$dir/sent.log"; : > "$sent"
  : > "$dir/pane.txt"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed for the buffered digest"
  [ "$(grep -c '\[ENTER\]' "$sent")" -eq 1 ] || fail "buffered digest was not submitted exactly once"
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after a successful flush"
  unset FM_FAKE_CREW_STATE FM_CREW_STATE_BIN
  pass "lifecycle: routine self-handles, terminal survives a watcher restart, buffers once, no dup, injects once"
}

# The incident shape is a turn-end marker with no terminal status. Away mode must
# reconcile the live task state before deciding the signal is routine. These four
# cases use separate state roots and the real watcher -> durable queue -> daemon
# routing path so no production task metadata, endpoint, or worktree is touched.
test_turn_end_reconciliation_shapes() {
  local dir state fakebin out drain_out reason key sent

  # Endpoint gone, no terminal status: escalate immediately with the task id and
  # a recovery recommendation. The retained worktree mirrors the orphan incident.
  dir=$(make_supercase turn-end-endpoint-gone)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; drain_out="$dir/drain.out"
  mkdir -p "$dir/worktree" "$dir/data/cv-v2-shared-master-a1"
  printf 'window=fixture:w1:p1\nbackend=herdr\nworktree=%s\nkind=ship\n' "$dir/worktree" \
    > "$state/cv-v2-shared-master-a1.meta"
  printf 'durable implementation report\n' > "$dir/data/cv-v2-shared-master-a1/report.md"
  : > "$state/cv-v2-shared-master-a1.turn-ended"
  touch -t 202001010000 "$state/cv-v2-shared-master-a1.turn-ended"
  FM_CREW_STATE_BIN=$(make_fake_crew_state "$fakebin")
  export FM_CREW_STATE_BIN
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validation still active · endpoint: gone'
  run_watcher_once "$state" "$fakebin" "$out" || fail "watcher did not surface the endpoint-gone turn-end"
  reason=$(<"$out")
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after endpoint-gone turn-end failed"
  FM_STATE_OVERRIDE="$state" handle_wake "$reason" "$state"
  grep -F 'task cv-v2-shared-master-a1' "$state/.subsuper-escalations" >/dev/null 2>&1 \
    || fail "endpoint-gone turn-end did not escalate with its task id"
  grep -F 'endpoint gone' "$state/.subsuper-escalations" >/dev/null 2>&1 \
    || fail "endpoint-gone turn-end did not describe the lost endpoint"
  grep -F 'recommended recovery:' "$state/.subsuper-escalations" >/dev/null 2>&1 \
    || fail "endpoint-gone turn-end did not recommend recovery"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "endpoint-gone turn-end was buffered more than once"
  sent="$dir/sent.log"; : > "$sent"; : > "$dir/pane.txt"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "endpoint-gone recovery digest did not flush"
  [ "$(grep -c '\[ENTER\]' "$sent")" -eq 1 ] || fail "endpoint-gone recovery digest was not submitted exactly once"
  [ ! -s "$state/.subsuper-escalations" ] || fail "endpoint-gone recovery buffer was not cleared after delivery"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "endpoint-gone recovery was rebuffered after delivery"
  [ -s "$dir/data/cv-v2-shared-master-a1/report.md" ] || fail "isolated durable report was lost during recovery routing"

  # Endpoint alive but idle, no terminal status: surface the unfinished task for
  # inspection and continuation instead of treating the turn-end as routine.
  unset FM_FAKE_CREW_STATE FM_CREW_STATE_BIN
  dir=$(make_supercase turn-end-idle)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; drain_out="$dir/drain.out"
  mkdir -p "$dir/worktree"
  printf 'window=fixture:w1:p2\nbackend=herdr\nworktree=%s\nkind=ship\n' "$dir/worktree" \
    > "$state/cv-v2-po-pilot-recover-n3.meta"
  : > "$state/cv-v2-po-pilot-recover-n3.turn-ended"
  FM_CREW_STATE_BIN=$(make_fake_crew_state "$fakebin")
  export FM_CREW_STATE_BIN
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available · endpoint: alive'
  run_watcher_once "$state" "$fakebin" "$out" || fail "watcher did not surface the idle turn-end"
  reason=$(<"$out")
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after idle turn-end failed"
  FM_STATE_OVERRIDE="$state" handle_wake "$reason" "$state"
  grep -F 'task cv-v2-po-pilot-recover-n3' "$state/.subsuper-escalations" >/dev/null 2>&1 \
    || fail "idle turn-end did not escalate with its task id"
  grep -F 'endpoint alive but idle' "$state/.subsuper-escalations" >/dev/null 2>&1 \
    || fail "idle turn-end did not describe the live idle endpoint"
  grep -F 'recommended action:' "$state/.subsuper-escalations" >/dev/null 2>&1 \
    || fail "idle turn-end did not recommend continuation"

  # A terminal status remains on the existing status-dedup path even when its
  # turn-end marker coalesces into the same wake.
  unset FM_FAKE_CREW_STATE FM_CREW_STATE_BIN
  dir=$(make_supercase turn-end-terminal)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; drain_out="$dir/drain.out"
  FM_CREW_STATE_BIN=$(make_fake_crew_state "$fakebin")
  export FM_CREW_STATE_BIN
  export FM_FAKE_CREW_STATE='state: done · source: status-log · ready in branch fm/cv-sw-control-g1 · endpoint: alive'
  printf 'done: ready in branch fm/cv-sw-control-g1\n' > "$state/cv-sw-control-g1.status"
  : > "$state/cv-sw-control-g1.turn-ended"
  run_watcher_once "$state" "$fakebin" "$out" || fail "watcher did not surface the terminal turn-end"
  reason=$(<"$out")
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after terminal turn-end failed"
  FM_STATE_OVERRIDE="$state" handle_wake "$reason" "$state"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "terminal turn-end did not produce exactly one deduplicated escalation"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "terminal turn-end was duplicated by the catch-all scan"

  # A declared external pause is retained for its bounded long-cadence recheck.
  # It must not be escalated as an orphan merely because the turn ended idle.
  unset FM_FAKE_CREW_STATE FM_CREW_STATE_BIN
  dir=$(make_supercase turn-end-paused)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; drain_out="$dir/drain.out"
  mkdir -p "$dir/worktree"
  printf 'window=fixture:w1:p3\nbackend=herdr\nworktree=%s\nkind=ship\n' "$dir/worktree" \
    > "$state/cv-v2-po-pilot-audit-q5.meta"
  printf 'paused: awaiting the declared external release\n' > "$state/cv-v2-po-pilot-audit-q5.status"
  : > "$state/cv-v2-po-pilot-audit-q5.turn-ended"
  FM_CREW_STATE_BIN=$(make_fake_crew_state "$fakebin")
  export FM_CREW_STATE_BIN
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the declared external release · endpoint: alive'
  run_watcher_once "$state" "$fakebin" "$out" || fail "watcher did not route the paused turn-end"
  reason=$(<"$out")
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after paused turn-end failed"
  FM_STATE_OVERRIDE="$state" handle_wake "$reason" "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "declared external pause was escalated as an orphan"
  key=$(printf '%s' 'cv-v2-po-pilot-audit-q5' | tr ':/.' '___')
  [ -e "$state/.subsuper-paused-$key" ] || fail "declared external pause did not retain bounded recheck tracking"

  unset FM_FAKE_CREW_STATE FM_CREW_STATE_BIN
  pass "turn-ended reconciliation covers endpoint gone, idle unfinished, terminal done, and declared external pause"
}

# --- Phase 2: stale working-pane transient -> persistent -> resumed ----------
test_stale_pane_transient_persistent_resume() {
  local dir state fakebin win key
  dir=$(make_supercase wd-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  win="sess:fm-stale-w2"
  key=$(printf '%s' "stale-w2" | tr ':/.' '___')
  printf 'window=%s\nkind=ship\n' "$win" > "$state/stale-w2.meta"
  printf 'working: compiling\n' > "$state/stale-w2.status"

  # Transient: first stale observation self-handles and records a marker.
  stale_marker_record "$win" "$state"
  case "$(FM_STATE_OVERRIDE="$state" classify_stale "$win" "$state")" in
    self\|*) : ;;
    *) fail "transient stale did not self-handle" ;;
  esac
  [ -e "$state/.subsuper-stale-$key" ] || fail "transient stale did not record a persistence marker"

  # Persistent: the marker ages past the threshold and the pane is still idle, so
  # housekeeping escalates exactly once and clears the marker.
  printf 'idle prompt $\n' > "$dir/pane.txt"
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  : > "$state/.subsuper-escalations" 2>/dev/null || true
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "persistent stale did not escalate"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "stale marker not cleared after escalation"

  # Resumed: a fresh transient marker but the pane is now busy -> housekeeping
  # clears the marker without escalating.
  stale_marker_record "$win" "$state"
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  printf 'Working...\n' > "$dir/pane.txt"
  : > "$state/.subsuper-escalations"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "resumed stale marker was not cleared"
  [ ! -s "$state/.subsuper-escalations" ] || fail "resumed (busy) stale was escalated"
  pass "lifecycle: stale pane transient self-handles, persistent escalates once and clears, resumed clears quietly"
}

test_routine_then_terminal_after_restart
test_turn_end_reconciliation_shapes
test_stale_pane_transient_persistent_resume
