#!/usr/bin/env bash
# tests/fm-watch-triage.test.sh - the always-on wake triage built into
# bin/fm-watch.sh and the shared classifier (bin/fm-classify-lib.sh). The watcher
# now absorbs the benign majority of wakes in bash and exits ONLY on an actionable
# wake, so firstmate's LLM re-arms once per actionable event instead of once per
# wake. These tests cover the classifier predicates as pure functions, then drive
# a real fm-watch.sh subprocess to assert the behavioral contract:
# provably-working no-verb wakes absorbed (no exit, no queue entry, suppressor
# advanced, beacon fresh), stopped-crew no-verb wakes surfaced (queue + exit),
# provably-working stale panes absorbed-then-escalated past the threshold,
# terminal-looking stale status lines overridden by an active run, the heartbeat
# backstop fail-safe, and afk coherence (no double-triage while the away-mode
# daemon owns supervision).
#
# Daemon-side classification/injection lives in fm-daemon.test.sh; watcher/lock
# liveness in fm-watcher-lock.test.sh; the durable-queue safety matrix in
# fm-wake-queue.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-tests)

# Common watcher knobs: tight poll/grace, no check or heartbeat cadence unless a
# test overrides them, so a test only exercises the path it targets. FM_CREW_STATE_BIN
# points at the case's hermetic fake fm-crew-state.sh (installed by make_case) so the
# absorb-only-when-provably-working triage reads a canned verdict; a test fixes that
# verdict via FM_FAKE_CREW_STATE in its environment before calling watch_bg.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

wait_numeric_file() {
  local file=$1 limit=${2:-30} i=0 value
  while [ "$i" -lt "$limit" ]; do
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in
      ''|*[!0-9]*) ;;
      *) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Portable mtime in epoch seconds. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see fm-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# --- pure classifier predicates (fm-classify-lib.sh) ------------------------

test_signal_reason_is_actionable_classifier() {
  local dir state
  dir=$(make_case classify-signal); state="$dir/state"
  printf 'working: step 1\nworking: step 2\n' > "$state/a.status"
  signal_reason_is_actionable "$state/a.status" && fail "benign working: signal classified actionable"
  printf 'working: x\nneeds-decision: pick A or B\n' > "$state/b.status"
  signal_reason_is_actionable "$state/b.status" || fail "captain-relevant signal classified benign"
  : > "$state/c.turn-ended"
  signal_reason_is_actionable "$state/c.turn-ended" && fail "a bare turn-ended marker classified actionable"
  # Coalesced batch: one benign + one captain-relevant -> actionable.
  signal_reason_is_actionable "$state/a.status" "$state/b.status" || fail "coalesced benign+actionable not actionable"
  pass "signal_reason_is_actionable: benign absorbed, captain verbs and coalesced batches surfaced"
}

test_stale_is_terminal_classifier() {
  local dir state
  dir=$(make_case classify-stale); state="$dir/state"
  printf 'done: ready in branch fm/x\n' > "$state/term.status"
  stale_is_terminal "sess:fm-term" "$state" || fail "terminal stale status not classified terminal"
  fm_write_meta "$state/herdr-term.meta" "window=default:w1:p2" "backend=herdr"
  printf 'done: ready in branch fm/herdr\n' > "$state/herdr-term.status"
  stale_is_terminal "default:w1:p2" "$state" || fail "terminal herdr stale status not resolved through metadata"
  printf 'working: compiling\n' > "$state/nonterm.status"
  stale_is_terminal "sess:fm-nonterm" "$state" && fail "non-terminal stale classified terminal"
  stale_is_terminal "sess:fm-missing" "$state" && fail "stale with no status classified terminal"
  pass "stale_is_terminal: terminal status surfaces, non-terminal and no-status are benign"
}

test_scan_captain_relevant_statuses_classifier() {
  local dir state out
  dir=$(make_case classify-scan); state="$dir/state"
  printf 'working: a\n' > "$state/one.status"
  printf 'blocked: no perms\n' > "$state/two.status"
  printf 'done: PR https://x/y/pull/1\n' > "$state/three.status"
  # Live tasks: fm-spawn writes the meta before the crewmate can append status, and
  # the scan skips any status log whose meta is gone (see the orphan test below).
  for t in one two three; do printf 'window=fm-%s\nkind=ship\n' "$t" > "$state/$t.meta"; done
  out=$(scan_captain_relevant_statuses "$state")
  printf '%s' "$out" | grep -F "two.status" >/dev/null || fail "scan missed a blocked: status"
  printf '%s' "$out" | grep -F "three.status" >/dev/null || fail "scan missed a done: status"
  printf '%s' "$out" | grep -F "one.status" >/dev/null && fail "scan surfaced a benign working: status"
  pass "scan_captain_relevant_statuses lists only captain-relevant statuses"
}

# The orphan guard. A status log whose task is gone (no meta) carries a settled
# terminal verb, not news; without this the catch-all fleet scan re-reports every
# lingering done:/blocked: line in state/ as a fresh captain escalation.
test_scan_skips_orphaned_status_logs() {
  local dir state out
  dir=$(make_case classify-orphan); state="$dir/state"
  printf 'done: shipped, task long torn down\n' > "$state/ghost.status"
  printf 'done: PR https://x/y/pull/2\n' > "$state/live.status"
  printf 'window=fm-live\nkind=ship\n' > "$state/live.meta"
  out=$(scan_captain_relevant_statuses "$state")
  printf '%s' "$out" | grep -F "live.status" >/dev/null || \
    fail "orphan guard dropped a live task's captain-relevant status"
  printf '%s' "$out" | grep -F "ghost.status" >/dev/null && \
    fail "scan surfaced an orphaned status log (no meta) as captain-relevant news"
  pass "scan_captain_relevant_statuses skips orphaned status logs, keeps live ones"
}

test_classifier_primitives() {
  local dir state
  dir=$(make_case classify-primitives); state="$dir/state"
  printf 'working: a\n\ndone: b\n\n' > "$state/x.status"
  [ "$(last_status_line "$state/x.status")" = "done: b" ] || fail "last_status_line did not return the last non-blank line"
  status_is_captain_relevant "done: b" || fail "done: not recognized as captain-relevant"
  status_is_captain_relevant "working: b" && fail "working: wrongly recognized as captain-relevant"
  [ "$(window_to_task "sess:fm-fix-login-k3")" = "fix-login-k3" ] || fail "window_to_task did not strip session+fm- prefix"
  fm_write_meta "$state/herdr-task.meta" "window=default:w1:p2" "backend=herdr"
  [ "$(window_to_task "default:w1:p2" "$state")" = "herdr-task" ] || fail "window_to_task did not resolve opaque backend target through metadata"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" || fail "FM_CAPTAIN_RE override not honored"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "done: x" && fail "FM_CAPTAIN_RE override did not replace the default verb set"
  pass "classifier primitives: last line, captain-relevance, window->task, FM_CAPTAIN_RE override"
}

# crew_is_provably_working: the absorb-only-when-provably-working predicate. It is
# benign (absorb) ONLY when fm-crew-state.sh reports the crew as working from an
# actively-running pipeline step (source run-step) or a busy pane (source pane);
# everything else - a stale working: status-log line, a finished/parked/failed run,
# an unknown/torn-down crew, or an empty id - is NOT provable, so it surfaces. The
# fake fm-crew-state.sh (FM_CREW_STATE_BIN) returns a canned verdict per case.
test_crew_is_provably_working_classifier() {
  local dir fakebin
  dir=$(make_case provably-working); fakebin="$dir/fakebin"
  # Point the predicate at this case's hermetic fake and drive its verdict per case.
  # export marks the var for the fake subprocess; it is unset again at the end so it
  # cannot leak into a later test (every behavioral test sets its own verdict anyway).
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  crew_is_provably_working a || fail "active run-step not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  crew_is_provably_working a || fail "busy pane not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  ! crew_is_provably_working a || fail "stale status-log working: treated as provably working"
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  ! crew_is_provably_working a || fail "finished run treated as provably working"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  ! crew_is_provably_working a || fail "parked run treated as provably working"
  FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  ! crew_is_provably_working a || fail "failed run treated as provably working"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  ! crew_is_provably_working a || fail "unknown crew treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: run-step · x'
  ! crew_is_provably_working "" || fail "empty id treated as provably working"
  unset FM_FAKE_CREW_STATE
  pass "crew_is_provably_working: only working+run-step/pane is provable; idle/finished/parked/failed/unknown surface"
}

# status_is_paused: the shared pause verb test both consumers read (so neither
# hardcodes the literal). Matches only the verb before the first colon, so a reason
# that merely mentions "paused" does not false-match, and a genuine blocker stays a
# blocker.
test_status_is_paused_classifier() {
  status_is_paused 'paused: holding for the upstream release' || fail "paused verb not recognized"
  status_is_paused '  paused:   waiting on a rate-limit reset' || fail "leading-space paused verb not recognized"
  status_is_paused 'blocked: the build is paused upstream' && fail "a blocked line mentioning paused false-matched"
  status_is_paused 'working: paused the animation loop' && fail "a working line mentioning paused false-matched"
  status_is_paused 'done: shipped' && fail "done classified as paused"
  status_is_paused '' && fail "empty line classified as paused"
  # A pause is deliberately NOT captain-relevant: it is a stop-nagging signal, not
  # work to keep surfacing.
  status_is_captain_relevant 'paused: holding for the upstream release' && fail "paused is captain-relevant (should not be)"
  pass "status_is_paused: only the leading paused verb matches, and paused is not captain-relevant"
}

# crew_absorb_class: the single fm-crew-state.sh read that returns BOTH absorb
# reasons - working (active run/busy pane), paused (declared external wait), or none
# (surface it) - so the watcher's stale path gets both for one bounded call.
# crew_is_paused delegates to it exactly as crew_is_provably_working does.
test_crew_absorb_class_classifier() {
  local dir fakebin
  dir=$(make_case absorb-class); fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_class a)" = working ] || fail "active run-step not classed working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  [ "$(crew_absorb_class a)" = working ] || fail "busy pane not classed working"
  FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting upstream'
  [ "$(crew_absorb_class a)" = paused ] || fail "declared pause not classed paused"
  crew_is_paused a || fail "crew_is_paused did not recognize a paused verdict"
  ! crew_is_provably_working a || fail "a paused crew was treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  [ "$(crew_absorb_class a)" = none ] || fail "stale working: status-log classed absorbable"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  [ "$(crew_absorb_class a)" = none ] || fail "unknown crew classed absorbable"
  ! crew_is_paused a || fail "unknown crew classed paused"
  [ "$(crew_absorb_class "")" = none ] || fail "empty id not classed none"
  unset FM_FAKE_CREW_STATE
  pass "crew_absorb_class: working/paused/none from one read; crew_is_paused and crew_is_provably_working agree"
}

# signal_crew_provably_working: a no-verb "signal:" wake is benign ONLY when EVERY
# task it references is provably working; if any crew has stopped, or no task can be
# resolved, it surfaces. Files map to ids by stripping .status / .turn-ended.
test_signal_crew_provably_working_classifier() {
  local dir fakebin state
  dir=$(make_case signal-provably-working); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE_a='state: working · source: run-step · running'
  export FM_FAKE_CREW_STATE_b='state: done · source: run-step · run passed'
  # Both are LIVE tasks: fm-spawn writes the meta before the crew can signal, and
  # its absence is what marks a signal file as an orphan below.
  printf 'window=fm-a\nkind=ship\n' > "$state/a.meta"
  printf 'window=fm-b\nkind=ship\n' > "$state/b.meta"
  signal_crew_provably_working "$state/a.status" "$state/a.turn-ended" \
    || fail "a single provably-working crew (status+turn-end) was not benign"
  ! signal_crew_provably_working "$state/a.status" "$state/b.turn-ended" \
    || fail "a coalesced batch including a stopped crew was treated as benign"
  ! signal_crew_provably_working "$state/b.turn-ended" \
    || fail "a stopped crew's bare turn-end was treated as benign"
  ! signal_crew_provably_working "$state/a.meta" \
    || fail "a non-signal file resolved to a benign verdict"
  ! signal_crew_provably_working \
    || fail "an empty signal file list was treated as benign"
  # Orphans absorb: a torn-down task's leftover turn-end marker carries no verb, so
  # without this it reaches the crew-state check, reads `unknown`, and surfaces a
  # wake for a crew that no longer exists.
  [ "$(crew_absorb_class ghost "$state")" = orphan ] || \
    fail "a signal file with no meta was not classed orphan"
  signal_crew_provably_working "$state/ghost.turn-ended" \
    || fail "an orphaned turn-end marker was surfaced instead of absorbed"
  signal_crew_provably_working "$state/ghost.status" \
    || fail "an orphaned status signal was surfaced instead of absorbed"
  # An orphan must not launder a live stopped crew in the same coalesced batch.
  ! signal_crew_provably_working "$state/ghost.turn-ended" "$state/b.turn-ended" \
    || fail "an orphan in the batch masked a live stopped crew"
  unset FM_FAKE_CREW_STATE_a FM_FAKE_CREW_STATE_b
  pass "signal_crew_provably_working: benign only when every referenced crew is provably working or gone"
}

# signal_reconciliation_detail turns one current-state line into the recovery
# guidance away mode acts on directly, so the guidance must never contradict the
# state it quotes. Precedence: a lost or unrecorded endpoint first (it makes the
# rest of the read unreliable), then the reported state, then the source.
test_signal_reconciliation_detail_precedence() {
  local dir state out
  dir=$(make_case reconcile-detail-precedence); state="$dir/state"

  # A checks-green crew monitoring its PR reports done FROM the status log. That
  # is a completion to record, not an unfinished task to continue.
  out=$(signal_reconciliation_detail "$state" pr-wait-p1 \
    'state: done · source: status-log · PR ready · run still monitoring PR' turn-end)
  case "$out" in
    *'reports done'*) ;;
    *) fail "a done crew reading from the status log was not described as done: $out" ;;
  esac
  case "$out" in
    *'continue the unfinished task'*) fail "done guidance contradicted the state it quotes: $out" ;;
  esac

  # A genuinely idle crew with no run to consult still gets continue-the-task guidance.
  out=$(signal_reconciliation_detail "$state" idle-p2 \
    'state: unknown · source: status-log · working: implementing' turn-end)
  case "$out" in
    *'endpoint alive but idle'*) ;;
    *) fail "an idle non-done crew lost its inspect-and-continue guidance: $out" ;;
  esac

  # Endpoint loss outranks a done state: the read itself is unreliable.
  out=$(signal_reconciliation_detail "$state" gone-p3 \
    'state: done · source: run-step · outcome: checks-passed · endpoint: gone' turn-end)
  case "$out" in
    *'endpoint gone'*) ;;
    *) fail "endpoint loss was shadowed by the reported state: $out" ;;
  esac
  pass "signal_reconciliation_detail ranks endpoint loss over state, and state over source"
}

# Every state that maps from a captain-relevant verb needs the action that state
# calls for. These reconciliations also retire the status for the catch-all scan,
# so a mis-framed line is the ONLY item the captain gets - away mode acts on the
# digest text, not on operator prose.
test_signal_reconciliation_detail_frames_each_captain_state() {
  local dir state out
  dir=$(make_case reconcile-detail-states); state="$dir/state"

  out=$(signal_reconciliation_detail "$state" parked-s1 \
    'state: parked · source: status-log · which auth provider? · endpoint: alive' turn-end)
  case "$out" in
    *'parked on a pending decision'*) ;;
    *) fail "a parked crew was not framed as awaiting a decision: $out" ;;
  esac
  case "$out" in
    *'continue the unfinished task'*) fail "parked guidance framed a pending decision as routine work: $out" ;;
  esac

  # `parked` has two owners. A run parked at its own validation gate is owed by
  # the CREW, so relaying it as a captain decision asks for an answer the captain
  # does not own while the crew idle-waits.
  out=$(signal_reconciliation_detail "$state" parked-s4 \
    'state: parked · source: run-step · parked at review: 2 finding(s) · endpoint: alive' turn-end)
  case "$out" in
    *'answer that gate'*) ;;
    *) fail "an agent-owed validation gate was not pointed back at the crew: $out" ;;
  esac
  case "$out" in
    *'surface that decision'*) fail "an agent-owed gate was relayed as the captain's decision: $out" ;;
  esac

  # The same run-step gate marked ask-user IS the captain's.
  out=$(signal_reconciliation_detail "$state" parked-s5 \
    'state: parked · source: run-step · parked at review: 1 finding(s) (ask-user: captain decision) · endpoint: alive' turn-end)
  case "$out" in
    *'surface that decision'*) ;;
    *) fail "an ask-user gate was not surfaced as the captain's decision: $out" ;;
  esac

  out=$(signal_reconciliation_detail "$state" blocked-s2 \
    'state: blocked · source: status-log · waiting on captain credentials · endpoint: alive' turn-end)
  case "$out" in
    *'reports blocked'*) ;;
    *) fail "a blocked crew was not framed as blocked: $out" ;;
  esac
  case "$out" in
    *'continue the unfinished task'*) fail "blocked guidance framed a blocker as routine work: $out" ;;
  esac
  case "$out" in
    *blocker*) ;;
    *) fail "blocked guidance did not point at the blocker: $out" ;;
  esac

  out=$(signal_reconciliation_detail "$state" failed-s3 \
    'state: failed · source: status-log · rc 2 from the build · endpoint: alive' turn-end)
  case "$out" in
    *'reports failed'*) ;;
    *) fail "a failed crew was not framed as failed: $out" ;;
  esac
  case "$out" in
    *'continue the unfinished task'*) fail "failed guidance framed a failure as routine work: $out" ;;
  esac
  case "$out" in
    *evidence*) ;;
    *) fail "failed guidance did not ask for the failure evidence: $out" ;;
  esac

  # A declared external pause is absorbed upstream and must not be reframed as
  # any of these, so the vocabularies stay distinct.
  [ "$(crew_absorb_class_from_line 'state: paused · source: status-log · awaiting the vendor reset · endpoint: alive')" = paused ] \
    || fail "a declared external pause stopped being absorbed as paused"
  pass "signal_reconciliation_detail gives parked, blocked and failed their own captain-facing action"
}

# "no terminal status" is a claim about the TASK, so it has to come from the
# status log rather than from which files the wake happened to name. A crew that
# reported done before the daemon started has no seen-status marker yet, and
# telling away mode it never reported points at relaunching finished work.
test_signal_reconciliation_detail_reads_the_status_log() {
  local dir state out
  dir=$(make_case reconcile-detail-status); state="$dir/state"
  printf 'working: building\ndone: PR https://x/y/pull/21 checks green\n' > "$state/rep-r5.status"

  out=$(signal_reconciliation_detail "$state" rep-r5 \
    'state: unknown · source: none · backend target gone: sess:fm-rep-r5 · endpoint: gone' turn-end)
  case "$out" in
    *'with no terminal status'*) fail "a crew that already reported done was described as having none: $out" ;;
  esac
  case "$out" in
    *'last reported: done: PR https://x/y/pull/21 checks green'*) ;;
    *) fail "the endpoint-loss detail carried no last-reported context: $out" ;;
  esac
  case "$out" in
    *'unless that last report shows the work already landed'*) ;;
    *) fail "the endpoint-loss detail lost its already-landed hedge: $out" ;;
  esac

  # A crew that genuinely never reported a terminal keeps the claim.
  printf 'working: building\n' > "$state/rep-r6.status"
  out=$(signal_reconciliation_detail "$state" rep-r6 \
    'state: unknown · source: none · backend target gone: sess:fm-rep-r6 · endpoint: gone' turn-end)
  case "$out" in
    *'after turn end with no terminal status'*) ;;
    *) fail "a crew with no terminal status lost that context: $out" ;;
  esac
  pass "signal_reconciliation_detail takes the terminal-status claim from the status log, not the wake's file list"
}

# Reconciliation confirms a lost endpoint in one bounded re-probe while the
# watcher needs several consecutive polls, so it is usually the FIRST detector to
# describe a dead secondmate - and it writes the shared episode record, which
# then suppresses the watcher's own wake. Its wording therefore has to be
# kind-aware too, or the captain-facing item names an artifact that does not
# exist.
test_signal_reconciliation_detail_is_kind_aware() {
  local dir state out
  dir=$(make_case reconcile-detail-kind); state="$dir/state"
  printf 'window=sess:fm-sec-k1\nkind=secondmate\nhome=%s\n' "$dir/home" > "$state/sec-k1.meta"
  printf 'window=sess:fm-crew-k2\nkind=ship\nworktree=%s\n' "$dir/wt" > "$state/crew-k2.meta"

  out=$(signal_reconciliation_detail "$state" sec-k1 \
    'state: unknown · source: none · backend target gone: sess:fm-sec-k1 · endpoint: gone' turn-end)
  case "$out" in
    *'relaunch it in its recorded firstmate home'*) ;;
    *) fail "a dead secondmate was given crewmate recovery wording: $out" ;;
  esac
  case "$out" in
    *worktree*) fail "a dead secondmate's recovery named a worktree it does not have: $out" ;;
  esac

  out=$(signal_reconciliation_detail "$state" crew-k2 \
    'state: unknown · source: none · backend target gone: sess:fm-crew-k2 · endpoint: gone' turn-end)
  case "$out" in
    *'resume or relaunch from recorded metadata and worktree'*) ;;
    *) fail "a dead crewmate lost its worktree recovery wording: $out" ;;
  esac
  pass "signal_reconciliation_detail gives a dead secondmate its home, not a worktree"
}

# Every sibling in the classifier takes the state dir explicitly. Reading it from
# an ambient global instead would silently read "/<task>.status" whenever a
# caller's state dir differs, emptying the last-reported context and re-adding
# the false "with no terminal status" claim.
test_signal_reconciliation_detail_uses_the_passed_state() {
  local dir state other out
  dir=$(make_case reconcile-detail-explicit-state); state="$dir/state"; other="$dir/other"
  mkdir -p "$other"
  printf 'done: PR https://x/y/pull/31 checks green\n' > "$other/rep-r7.status"
  # The ambient state dir deliberately holds a DIFFERENT story for the same task.
  printf 'working: still building\n' > "$state/rep-r7.status"

  out=$(STATE="$state" FM_STATE_OVERRIDE="$state" signal_reconciliation_detail "$other" rep-r7 \
    'state: unknown · source: none · backend target gone: sess:fm-rep-r7 · endpoint: gone' turn-end)
  case "$out" in
    *'last reported: done: PR https://x/y/pull/31 checks green'*) ;;
    *) fail "the detail read an ambient state dir instead of the one it was passed: $out" ;;
  esac
  case "$out" in
    *'with no terminal status'*) fail "the passed state dir's terminal status was missed: $out" ;;
  esac
  pass "signal_reconciliation_detail reads the state dir it is given, not an ambient global"
}

# --reconcile appends a dedicated `endpoint:` field last, and that field is the
# only authority on endpoint liveness. A crew's own status note is free text that
# lands in the detail field ahead of it - a crewmate reporting a dead sub-agent
# as "blocked: backend target gone: <child>" must not be read as having lost its
# OWN endpoint, or away mode is told to relaunch a live crew.
test_endpoint_verdict_ignores_free_text_status_detail() {
  local line

  line='state: blocked · source: status-log · backend target gone: sess:fm-child-x · endpoint: alive'
  ! crew_state_endpoint_lost "$line" \
    || fail "a live endpoint was read as lost because the crew's own note mentioned one"
  [ "$(crew_absorb_class_from_line "$line")" = none ] \
    || fail "a blocked crew with a live endpoint stopped being actionable"

  line='state: working · source: run-step · child pane reported endpoint: gone · endpoint: alive'
  ! crew_state_endpoint_lost "$line" \
    || fail "free text naming a gone endpoint outranked the authoritative field"
  [ "$(crew_absorb_class_from_line "$line")" = working ] \
    || fail "a provably working crew was surfaced because its note mentioned a gone endpoint"

  # The authoritative field still decides a real loss.
  line='state: unknown · source: none · backend target gone: sess:fm-real · endpoint: gone'
  crew_state_endpoint_lost "$line" || fail "a genuinely lost endpoint stopped being recognised"
  [ "$(crew_absorb_class_from_line "$line")" = none ] || fail "a lost endpoint became absorbable"

  # A line with no such field (the default operator read) keeps the old evidence.
  line='state: unknown · source: none · backend target gone: sess:fm-legacy'
  crew_state_endpoint_lost "$line" \
    || fail "a line without the dedicated field lost its fallback recognition"
  pass "the dedicated endpoint field decides endpoint loss, never the crew's free-text detail"
}

# --- benign wakes are absorbed ONLY when the crew is provably working ---------

test_provably_working_signal_absorbed() {
  local dir state fakebin out status_file pid
  dir=$(make_case provably-working-signal); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'window=fm-task\nkind=ship\n' > "$state/task.meta"
  printf 'working: compiling step 2\n' > "$status_file"
  # The crew's pipeline is in an actively-running step: positive evidence it is
  # still working, so a no-verb working: signal is absorbed (the original low-churn
  # case during a long validation).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a working: signal whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working signal printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working signal enqueued a durable wake record"
  [ -s "$state/.seen-task_status" ] || fail "provably-working signal did not advance its .seen-* suppressor"
  [ -e "$state/.last-watcher-beat" ] || fail "watcher beacon was not touched while absorbing"
  reap "$pid"
  pass "a no-verb signal whose crew is provably working is absorbed (no exit, no queue, suppressor advanced, beacon present)"
}

test_turn_ended_provably_working_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case turn-ended-working); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  : > "$state/task.turn-ended"
  printf 'window=fm-task\nkind=ship\n' > "$state/task.meta"
  # A busy pane is the second form of positive evidence (covers a queued
  # continuation right after the turn-end).
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a turn-end whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working turn-end printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working turn-end enqueued a durable wake record"
  reap "$pid"
  pass "a bare turn-end whose crew is provably working (busy pane) is absorbed"
}

# --- a no-verb signal whose crew is NOT provably working SURFACES -------------
# This is the swallowed-finish fix: a crew that finished (or stopped and waits)
# reports its final turn-end with no captain-relevant status and no running
# pipeline, so the wake must surface instead of being absorbed.

test_turn_ended_not_working_surfaced() {
  local dir state fakebin out drain_out pid
  dir=$(make_case turn-ended-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  : > "$state/task.turn-ended"
  # A LIVE task (meta present) that stopped: the orphan absorb must not reach it.
  printf 'window=fm-task\nkind=ship\n' > "$state/task.meta"
  # No running pipeline, no busy pane: the crew has stopped (e.g. it finished via
  # an interactive menu and wrote no done: status). Default unknown verdict.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a turn-end whose crew is not provably working"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null || fail "watcher did not print the surfaced turn-end signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/task.turn-ended" >/dev/null || fail "surfaced turn-end was not queued"
  pass "a bare turn-end whose crew is not provably working is surfaced (the swallowed-finish fix)"
}

test_working_note_not_working_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case working-note-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'window=fm-task\nkind=ship\n' > "$state/task.meta"
  printf 'working: compiling step 2\n' > "$status_file"
  # A non-no-mistakes crew (no run) whose pane went idle: fm-crew-state falls back
  # to the stale working: status-log line. That is NOT positive evidence, so the
  # wake must surface - these users must never be left hanging.
  export FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling step 2'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a working: note whose crew has no running pipeline and an idle pane"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the surfaced working: signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced working: note failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "surfaced working: note was not queued"
  [ -s "$state/.seen-task_status" ] || fail "surfaced working: note did not advance its .seen-* suppressor"
  pass "a no-verb working: note whose crew is idle with no running pipeline is surfaced"
}

# --- actionable wakes are surfaced (queue + exit) ---------------------------

test_actionable_signal_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case actionable-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'window=fm-task\nkind=ship\n' > "$state/task.meta"
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for an actionable needs-decision signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the actionable signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "actionable signal was not queued"
  [ -s "$state/.hb-surfaced-task" ] || fail "actionable signal did not record the surfaced marker"
  pass "captain-relevant signal is surfaced (queue + exit) and marked surfaced"
}

test_terminal_stale_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-done"
  printf 'finished, awaiting review' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/done.meta"
  printf 'done: PR https://example.test/pr/3\n' > "$state/done.status"
  sig=$(seen_sig "$state/done.status"); printf '%s' "$sig" > "$state/.seen-done_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "finished, awaiting review")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for a stale pane on a terminal status"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the terminal stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the terminal stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "terminal stale was not queued"
  pass "a stale pane sitting on a terminal status is surfaced (queue + exit)"
}

# --- stale pane, STALE terminal status overridden by an active run: absorbed ---
# Regression for the 2026-07 herdr false-surface incidents: a crew's own status
# log gets no new entry once firstmate hands it to a no-mistakes validation
# (AGENTS.md's sparse status-reporting contract), so the log keeps showing its
# pre-validation "done:" line as the LAST line for the run's entire (possibly
# many-minutes) duration. stale_is_terminal alone has no run-step awareness and
# would treat that leftover as still-current every time the pane goes quiet,
# immediately surfacing a crew that is actively validating. crew_is_provably_working
# must get a chance to override a captain-relevant-but-stale status line, exactly
# as it already does for a plain non-terminal one.
test_stale_terminal_status_overridden_by_active_run() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale-overridden); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-validating"
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/validating.meta"
  # The crew reported done BEFORE firstmate triggered no-mistakes validation;
  # this line never gets superseded by a newer status-log entry while the
  # pipeline itself runs.
  printf 'done: implementation complete, ready to validate\n' > "$state/validating.status"
  sig=$(seen_sig "$state/validating.status"); printf '%s' "$sig" > "$state/.seen-validating_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: a high escalation threshold means the first sighting is absorbed,
  # not surfaced, despite the captain-relevant "done:" status-log line.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a stale terminal-looking status the run-step overrides (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the overridden stale terminal status printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "the overridden stale terminal status enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  [ ! -e "$state/.hb-surfaced-validating" ] || fail "an absorbed wake must not mark the status line as surfaced"
  reap "$pid"

  # Phase B: backdate the idle timer past the threshold; the run genuinely
  # wedges and the next poll escalates exactly like the non-terminal case.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not escalate an overridden stale terminal status past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  unset FM_FAKE_CREW_STATE
  pass "a stale terminal-looking status is overridden and absorbed while a run is actively working, then wedge-escalated"
}

# --- non-terminal stale, crew provably working: absorbed, then wedge-escalated ---
# A provably-working crew (an actively-running pipeline) legitimately sits on a
# static pane (e.g. waiting on CI), so a non-terminal stale is absorbed and only
# the wedge timer eventually escalates it - the low-churn behavior preserved.

test_nonterminal_stale_provably_working_absorbed_then_escalated() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-working); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet.meta"
  # Non-terminal status, and prime .seen-* so the signal scan does not pre-empt
  # the stale path.
  printf 'working: still compiling\n' > "$state/quiet.status"
  sig=$(seen_sig "$state/quiet.status"); printf '%s' "$sig" > "$state/.seen-quiet_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  # Phase A: a high escalation threshold means the first sighting is absorbed.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a fresh provably-working non-terminal stale (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh provably-working stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh provably-working stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  reap "$pid"

  # Phase B: backdate the idle timer past the threshold; the next run escalates.
  # (The subsequent-sight timer path does not re-read the crew state.)
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not escalate a provably-working non-terminal stale past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer was not cleared after escalation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the wedge escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "wedge escalation was not queued"
  pass "provably-working non-terminal stale is absorbed on first sight, then wedge-escalated past the threshold"
}

# --- non-terminal stale, crew NOT provably working: surfaced immediately ------
# The key requirement: a crew with no running pipeline that has gone quiet (and is
# not busy) has stopped - it may be done via interactive menus, waiting, or wedged.
# It must surface at once, never wait out the wedge timer, so these users (a
# non-no-mistakes crew, or any crew with no running pipeline) are never left hanging.

test_nonterminal_stale_not_working_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (the crew never wrote a captain-relevant verb), .seen-*
  # primed so the signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  sig=$(seen_sig "$state/stopped.status"); printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No running pipeline; the pane is idle. NOT provably working.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  # Even with a high wedge threshold, a not-provably-working stale surfaces at once.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a not-provably-working non-terminal stale at once"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  grep -F "possible wedge" "$out" >/dev/null && fail "an immediate stopped-crew stale was mislabeled a wedge"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced on surface"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer should not be set when surfacing immediately"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the immediate stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  pass "a not-provably-working non-terminal stale is surfaced immediately (never left to wait out the timer)"
}

# --- endpoint liveness: an endpoint that dies without ever signalling again ----
# The 2026-08-10 orphan. When a crew's endpoint dies mid-turn the harness turn-end
# hook never runs, so no status line and no turn-end marker are ever written
# again: no signal wake fires, the stale layer has no pane to hash, and the
# heartbeat backstop only scans captain-relevant statuses. The task would stay in
# flight forever with nothing escalated.

test_unreadable_endpoint_surfaces_once_per_episode() {
  local dir state fakebin out drain_out window key pid
  dir=$(make_case endpoint-unreadable); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  window="test:fm-orphan-e1"
  # Recorded in-flight metadata plus an already-surfaced status, so no signal
  # wake can fire for this task and only the endpoint path can reach it.
  printf 'window=%s\nkind=ship\n' "$window" > "$state/orphan-e1.meta"
  printf 'working: implementing\n' > "$state/orphan-e1.status"
  printf '%s' "$(seen_sig "$state/orphan-e1.status")" > "$state/.seen-orphan-e1_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE_FAIL=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_ENDPOINT_MISS_GAP=3600 FM_ENDPOINT_MISS_POLLS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 60 || fail "watcher never surfaced a recorded endpoint that stayed unreadable"
  grep -F "check: endpoint $window" "$out" >/dev/null \
    || fail "watcher did not print the endpoint-liveness wake: $(cat "$out")"
  grep -F "task orphan-e1" "$out" >/dev/null || fail "the endpoint wake did not carry its task id"
  grep -F "last reported: working: implementing" "$out" >/dev/null \
    || fail "the endpoint wake did not carry what the task last reported: $(cat "$out")"
  grep -F "recommended recovery:" "$out" >/dev/null || fail "the endpoint wake carried no recovery guidance"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the endpoint wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "endpoint $window" >/dev/null \
    || fail "the endpoint wake was not durably queued"
  [ -e "$state/.endpoint-surfaced-$key" ] || fail "the episode marker was not recorded"

  # Same unreadable endpoint on later polls: already surfaced, so no second wake.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE_FAIL=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_ENDPOINT_MISS_GAP=3600 FM_ENDPOINT_MISS_POLLS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch2.out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "an already-surfaced unreadable endpoint woke firstmate again: $(cat "$dir/watch2.out")"
  fi
  reap "$pid"
  pass "a recorded endpoint that stays unreadable surfaces once per episode with its task id and recovery guidance"
}

test_transient_capture_failure_absorbed() {
  # One (or a few) failed probes are not proof: a backend CLI timeout or a
  # momentarily unreachable server fails every task at once. Below the threshold
  # the watcher must keep working without waking firstmate.
  local dir state fakebin out window key pid misses
  dir=$(make_case endpoint-transient); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  window="test:fm-blip-e2"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/blip-e2.meta"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE_FAIL=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_ENDPOINT_MISS_GAP=3600 FM_ENDPOINT_MISS_POLLS=99 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a capture failure below the miss threshold woke firstmate: $(cat "$out")"
  fi
  # The miss marker is "<count> <epoch of that miss>"; the epoch is what makes
  # the run consecutive rather than cumulative.
  misses=$(cut -d' ' -f1 "$state/.endpoint-miss-$key" 2>/dev/null || echo 0)
  [ "$misses" -ge 2 ] || fail "consecutive probe misses were not accumulated (got '$misses')"
  [ ! -s "$state/.wake-queue" ] || fail "a sub-threshold capture failure enqueued a durable wake"
  [ ! -e "$state/.endpoint-surfaced-$key" ] || fail "a sub-threshold capture failure marked the episode surfaced"
  reap "$pid"
  pass "capture failures below the miss threshold are absorbed and only counted"
}

test_stale_miss_does_not_pair_with_a_later_blip() {
  # A poll does not necessarily probe every window - any wake exits the process,
  # and under afk a queued signal skips the window loop entirely - so a bare
  # count would let one old transient blip pair with an unrelated later one and
  # "confirm" a loss for a crew that is alive. Only back-to-back misses count.
  local dir state fakebin out window key pid misses
  dir=$(make_case endpoint-stale-miss); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  window="test:fm-blip-e4"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/blip-e4.meta"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # An old run left behind by polls that were interrupted before probing this
  # window, in the count-only form a cumulative counter writes. It carries no
  # evidence of being recent, so it must not continue into this poll's run.
  printf '5' > "$state/.endpoint-miss-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE_FAIL=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_ENDPOINT_MISS_POLLS=99 FM_ENDPOINT_MISS_GAP=3 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 20; then
    reap "$pid"; fail "the sub-threshold run woke firstmate: $(cat "$out")"
  fi
  misses=$(cut -d' ' -f1 "$state/.endpoint-miss-$key" 2>/dev/null || echo 0)
  [ "$misses" -ge 1 ] || fail "the fresh miss was not recorded (got '$misses')"
  [ "$misses" -lt 5 ] \
    || fail "an hour-old miss run was carried forward instead of restarting (got '$misses')"
  reap "$pid"
  rm -f "$state/.endpoint-miss-$key"

  # Back-to-back misses within the window still confirm the loss.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE_FAIL=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_ENDPOINT_MISS_POLLS=2 FM_ENDPOINT_MISS_GAP=3600 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch2.out" &
  pid=$!
  wait_for_exit "$pid" 60 || fail "consecutive misses no longer confirm a lost endpoint"
  grep -F "check: endpoint $window" "$dir/watch2.out" >/dev/null \
    || fail "the confirmed loss was not surfaced: $(cat "$dir/watch2.out")"
  pass "an old miss cannot pair with a later blip, while back-to-back misses still confirm"
}

test_secondmate_endpoint_wake_names_its_home() {
  # A secondmate has no task worktree: it is recovered by relaunching in its own
  # firstmate home, so the crewmate wording would send away mode at the wrong
  # artifact.
  local dir state fakebin out window pid
  dir=$(make_case endpoint-secondmate-wording); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  window="test:fm-second-s3"
  printf 'window=%s\nkind=secondmate\nhome=%s\n' "$window" "$dir/home" > "$state/second-s3.meta"
  printf 'working: supervising its own fleet\n' > "$state/second-s3.status"
  printf '%s' "$(seen_sig "$state/second-s3.status")" > "$state/.seen-second-s3_status"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE_FAIL=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_ENDPOINT_MISS_GAP=3600 FM_ENDPOINT_MISS_POLLS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 60 || fail "a dead secondmate endpoint was never surfaced"
  grep -F "task second-s3" "$out" >/dev/null || fail "the secondmate endpoint wake lost its id"
  grep -F "relaunch it in its recorded firstmate home" "$out" >/dev/null \
    || fail "the secondmate endpoint wake gave crewmate recovery wording: $(cat "$out")"
  grep -F "worktree" "$out" >/dev/null \
    && fail "the secondmate endpoint wake named a worktree it does not have: $(cat "$out")"
  pass "a dead secondmate endpoint is recovered by its home, not by a worktree it has no notion of"
}

test_every_lost_endpoint_surfaces_independently() {
  # Endpoints that die at DIFFERENT times must each get their own recovery item.
  # This is the shape a fleet-level "all endpoints unreadable" inference would
  # misread: by the time the second one dies, every recorded endpoint happens to
  # be unreadable, and collapsing that into one verdict would leave the newest
  # genuine loss permanently unsurfaced.
  local dir state fakebin out pane pid i win
  dir=$(make_case endpoint-sequential); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; pane="$dir/pane.txt"
  # A busy signature keeps the readable pane out of the stale layer, so this test
  # exercises only the endpoint decision.
  printf 'building\nesc to interrupt\n' > "$pane"
  for i in 1 2; do
    win="test:fm-seq-d$i"
    printf 'window=%s\nkind=ship\n' "$win" > "$state/seq-d$i.meta"
    printf 'working: implementing\n' > "$state/seq-d$i.status"
    printf '%s' "$(seen_sig "$state/seq-d$i.status")" > "$state/.seen-seq-d${i}_status"
  done

  # First endpoint dies while the second is still readable.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_FAKE_TMUX_CAPTURE_FAIL_TARGETS="test:fm-seq-d1" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_ENDPOINT_MISS_GAP=3600 FM_ENDPOINT_MISS_POLLS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 60 || fail "the first lost endpoint was never surfaced"
  grep -F "check: endpoint test:fm-seq-d1" "$out" >/dev/null \
    || fail "the first lost endpoint was not reported per task: $(cat "$out")"

  # Later the second one dies too, so now EVERY recorded endpoint is unreadable.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE_FAIL=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_ENDPOINT_MISS_GAP=3600 FM_ENDPOINT_MISS_POLLS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch2.out" &
  pid=$!
  wait_for_exit "$pid" 60 || fail "the second lost endpoint was never surfaced"
  grep -F "check: endpoint test:fm-seq-d2" "$dir/watch2.out" >/dev/null \
    || fail "the second lost endpoint was swallowed once the whole fleet read as unreadable: $(cat "$dir/watch2.out")"
  grep -F "task seq-d2" "$dir/watch2.out" >/dev/null \
    || fail "the second endpoint wake lost its task id"
  [ -e "$state/.endpoint-surfaced-$(printf '%s' 'test:fm-seq-d2' | tr ':/.' '___')" ] \
    || fail "the second lost endpoint recorded no episode marker"
  pass "endpoints lost at different times each surface their own recovery item"
}

test_endpoint_wake_not_suppressed_when_the_queue_append_fails() {
  # The once-per-episode marker must never outlive a failed durable enqueue. A
  # dead endpoint never produces the successful capture that would clear the
  # marker, so suppressing on an unqueued wake would silence the orphan forever -
  # the exact failure this check exists to break.
  local dir state fakebin out window key pid status
  dir=$(make_case endpoint-append-fails); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  window="test:fm-append-e3"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/append-e3.meta"
  printf 'working: implementing\n' > "$state/append-e3.status"
  printf '%s' "$(seen_sig "$state/append-e3.status")" > "$state/.seen-append-e3_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # Make the durable queue's sequence write fail: a directory cannot be written
  # to as a file, so fm_wake_append returns non-zero exactly as a full or
  # read-only state dir would.
  mkdir -p "$state/.wake-queue.seq"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE_FAIL=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_ENDPOINT_MISS_GAP=3600 FM_ENDPOINT_MISS_POLLS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_for_exit "$pid" 60; status=$?
  [ "$status" -ne 124 ] || fail "the watcher never reached the failing durable enqueue"
  [ "$status" -ne 0 ] || fail "the watcher reported success despite a failed durable enqueue"
  [ ! -e "$state/.endpoint-surfaced-$key" ] \
    || fail "the episode was marked surfaced even though its wake was never queued"

  # Queue writable again: the same unreadable endpoint must still surface.
  rmdir "$state/.wake-queue.seq"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE_FAIL=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_ENDPOINT_MISS_GAP=3600 FM_ENDPOINT_MISS_POLLS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch2.out" &
  pid=$!
  wait_for_exit "$pid" 60 || fail "the endpoint stayed silent after the queue recovered"
  grep -F "check: endpoint $window" "$dir/watch2.out" >/dev/null \
    || fail "the recovered run did not surface the endpoint wake: $(cat "$dir/watch2.out")"
  grep "$(printf '\tcheck\t')" "$state/.wake-queue" | grep -F "endpoint $window" >/dev/null \
    || fail "the recovered endpoint wake was not durably queued"
  pass "a failed durable enqueue leaves the endpoint episode unsuppressed so it surfaces on recovery"
}

test_endpoint_loss_confirmed_while_siblings_keep_signalling() {
  # A wake exits the poll, so an endpoint probe evaluated after the signal scan
  # is skipped on every poll a chatty sibling crewmate signals - and under afk
  # every signal wakes. The crew whose endpoint died can never signal again, so
  # it would only ever be probed on the polls its siblings happened to stay
  # quiet, and the miss run would expire between them.
  local dir state fakebin pane out window key pid misses
  dir=$(make_case endpoint-starved); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; pane="$dir/pane.txt"
  window="test:fm-orphan-s5"
  printf 'building\nesc to interrupt\n' > "$pane"
  date '+%s' > "$state/.afk"   # away mode: the daemon owns triage, so every signal wakes
  # A sibling whose status keeps changing, so a signal is pending on every poll.
  printf 'window=test:fm-chatty-c5\nkind=ship\n' > "$state/chatty-c5.meta"
  printf 'working: building\n' > "$state/chatty-c5.status"
  # The orphan: its endpoint is dead and its own status is already surfaced, so
  # nothing but the liveness probe can reach it again.
  printf 'window=%s\nkind=ship\n' "$window" > "$state/orphan-s5.meta"
  printf 'working: implementing\n' > "$state/orphan-s5.status"
  printf '%s' "$(seen_sig "$state/orphan-s5.status")" > "$state/.seen-orphan-s5_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_FAKE_TMUX_CAPTURE_FAIL_TARGETS="$window" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_ENDPOINT_MISS_GAP=3600 FM_ENDPOINT_MISS_POLLS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 60 || fail "the watcher never handled the sibling's signal"
  grep -F "signal:" "$out" >/dev/null || fail "the sibling's signal was not the wake: $(cat "$out")"
  misses=$(cut -d' ' -f1 "$state/.endpoint-miss-$key" 2>/dev/null || echo 0)
  [ "$misses" -ge 1 ] \
    || fail "the dead endpoint went unprobed on a poll the sibling's signal ended (got '$misses')"

  # A second poll, again ended by a sibling signal: the miss run must still reach
  # the threshold and surface the orphan.
  printf 'working: still building\n' >> "$state/chatty-c5.status"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_FAKE_TMUX_CAPTURE_FAIL_TARGETS="$window" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_ENDPOINT_MISS_GAP=3600 FM_ENDPOINT_MISS_POLLS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch2.out" &
  pid=$!
  wait_for_exit "$pid" 60 || fail "the starved endpoint loss was never confirmed"
  grep -F "check: endpoint $window" "$dir/watch2.out" >/dev/null \
    || fail "a chatty sibling starved the dead endpoint out of being surfaced: $(cat "$dir/watch2.out")"
  grep -F "task orphan-s5" "$dir/watch2.out" >/dev/null \
    || fail "the starved endpoint wake lost its task id"
  pass "a dead endpoint is still confirmed while a sibling keeps the signal scan busy"
}

test_secondmate_unreadable_endpoint_surfaces() {
  # A secondmate's IDLE PANE is healthy, which is why stale-pane wakes skip it -
  # but a DEAD endpoint is a different condition, and it takes the secondmate's
  # whole subtree unsupervised. The only other detector runs at session start,
  # which a long away-mode stretch never reaches.
  local dir state fakebin out window pid
  dir=$(make_case secondmate-endpoint); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  window="test:fm-second-s1"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/second-s1.meta"
  printf 'working: supervising its own fleet\n' > "$state/second-s1.status"
  printf '%s' "$(seen_sig "$state/second-s1.status")" > "$state/.seen-second-s1_status"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE_FAIL=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_ENDPOINT_MISS_GAP=3600 FM_ENDPOINT_MISS_POLLS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 60 || fail "a secondmate whose endpoint died was never surfaced"
  grep -F "check: endpoint $window" "$out" >/dev/null \
    || fail "the secondmate endpoint wake was not emitted: $(cat "$out")"
  grep -F "task second-s1" "$out" >/dev/null || fail "the secondmate endpoint wake did not carry its id"
  pass "a secondmate whose endpoint becomes unreadable is surfaced, while its idle pane stays healthy"
}

test_secondmate_idle_pane_still_absorbed() {
  # The pane-staleness exemption must survive the endpoint check: a readable but
  # unchanging secondmate pane is still healthy and must not wake firstmate.
  local dir state fakebin out window pane pid
  dir=$(make_case secondmate-idle); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; pane="$dir/pane.txt"
  window="test:fm-second-s2"
  printf 'idle, waiting on its own watcher\n' > "$pane"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/second-s2.meta"
  printf 'working: supervising its own fleet\n' > "$state/second-s2.status"
  printf '%s' "$(seen_sig "$state/second-s2.status")" > "$state/.seen-second-s2_status"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_ENDPOINT_MISS_GAP=3600 FM_ENDPOINT_MISS_POLLS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_STALE_ESCALATE_SECS=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 40; then
    reap "$pid"; fail "an idle but readable secondmate pane woke firstmate: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "an idle but readable secondmate pane enqueued a wake"
  reap "$pid"
  pass "a readable but unchanging secondmate pane stays absorbed by the stale-pane exemption"
}

# --- non-terminal stale, crew DECLARED a pause: absorbed, re-surfaced on a long
#     cadence, never wedge-escalated ------------------------------------------
# The live 2026-07-09/10 case: a crew intentionally held awaiting an upstream tool
# release (paused: ...) whose idle pane tripped repeated possible-wedge escalations
# all day. With the paused verb, its stale is absorbed like a working crew but never
# uses the wedge timer; it re-surfaces once past PAUSE_RESURFACE_SECS (anchored on
# the pause's own status-file age, so a churny idle pane cannot reset the cadence)
# for a recheck, so a forgotten pause cannot rot invisibly.
test_nonterminal_stale_paused_absorbed_then_resurfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back statusf
  dir=$(make_case nonterminal-stale-paused); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-held"
  printf 'idle, holding for upstream' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/held.meta"
  statusf="$state/held.status"
  # A DECLARED pause (not captain-relevant), .seen-* primed so the signal scan does
  # not pre-empt the stale path.
  printf 'paused: holding for the upstream tool release\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, holding for upstream")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # crew_absorb_class reads the declared pause from fm-crew-state.sh.
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · holding for the upstream tool release'

  # Phase A: a fresh pause (status file just written) under a high re-surface
  # threshold is absorbed - no wake, no wedge timer.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a fresh declared pause (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh paused stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh paused stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on paused absorb"
  [ -e "$state/.paused-$key" ] || fail "paused flag not recorded on absorb"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused absorb must not start the wedge timer"
  reap "$pid"

  # Phase B: age the pause past the (now normal) threshold by backdating its
  # status file, re-prime .seen-* to the new signature so the signal scan stays
  # quiet, and confirm it re-surfaces as a paused recheck - never a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  : > "$out"
  printf 'idle, holding for upstream (token 2)' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not re-surface a declared pause past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "re-surface did not print a stale wake"
  grep -F "awaiting external" "$out" >/dev/null || fail "re-surface was not labeled a paused/awaiting-external recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause was mislabeled a possible wedge"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the paused re-surface throttle marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused re-surface must not use the wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the paused re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "paused re-surface was not queued"
  pass "a declared pause is absorbed on first sight, then re-surfaced as a recheck past the threshold, never wedge-escalated"
}

test_secondmate_paused_resurfaces_in_normal_mode() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case secondmate-paused-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-held.status"
  window="test:fm-secondmate-held"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-held.meta"
  printf 'paused: awaiting the upstream release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-held_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not re-surface a paused secondmate"
  grep -F "stale: $window" "$out" >/dev/null || fail "paused secondmate did not emit a stale recheck"
  grep -F "awaiting external" "$out" >/dev/null || fail "paused secondmate recheck omitted its external-wait reason"
  grep -F "possible wedge" "$out" >/dev/null && fail "paused secondmate was mislabeled a wedge"
  unset FM_FAKE_CREW_STATE
  pass "a declared paused secondmate re-surfaces on the bounded normal-mode cadence"
}

test_secondmate_nonpaused_stale_remains_suppressed() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid
  dir=$(make_case secondmate-stale-suppressed); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-working.status"
  window="test:fm-secondmate-working"
  printf 'idle while the parent supervises\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-working.meta"
  printf 'working: the parent supervises this secondmate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-working_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle while the parent supervises")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher surfaced an ordinary secondmate stale pane: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "ordinary secondmate stale pane printed a wake reason: $(cat "$out")"; }
  reap "$pid"
  pass "a non-paused secondmate retains normal stale suppression"
}

test_secondmate_unpause_clears_pause_tracking() {
  local dir state fakebin out statusf window key pid
  dir=$(make_case secondmate-unpause-clears); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; statusf="$state/secondmate-resumed.status"; window="test:fm-secondmate-resumed"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-resumed.meta"
  printf 'working: upstream landed\n' > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-secondmate-resumed_status"
  key=${window//:/_}
  key=${key//\//_}
  key=${key//./_}
  : > "$state/.paused-$key"
  : > "$state/.paused-rechecked-$key"
  : > "$state/.paused-resurfaced-$key"
  : > "$state/.stale-$key"
  : > "$state/.stale-since-$key"
  : > "$state/.wedge-escalations-$key"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_live "$pid" 20 || fail "watcher exited while reconciling a resumed secondmate: $(cat "$out")"
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "resumed secondmate retained the pause marker"; }
  [ ! -e "$state/.stale-$key" ] || { reap "$pid"; fail "resumed secondmate retained stale tracking"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "resumed secondmate retained wedge tracking"; }
  reap "$pid"
  pass "a resumed secondmate clears pause and stale tracking before stale exemption"
}

test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-pause-transition); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-transition"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/transition.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"
  fi
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash did not enter paused mode"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "pause transition retained its wedge timer"; }
  reap "$pid"

  printf 'working: upstream landed, resuming\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"
  fi
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash retained paused mode after resume"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "unchanged stale hash did not restart wedge tracking after resume"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "unchanged stale hashes reclassify when a crew enters or leaves pause"
}

test_nonterminal_paused_rechecks_authoritative_state() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-paused-recheck); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-pause-recheck"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/pause-recheck.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/pause-recheck.status"
  sig=$(seen_sig "$state/pause-recheck.status"); printf '%s' "$sig" > "$state/.seen-pause-recheck_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "an active run behind a declared pause surfaced instead of resuming wedge tracking: $(cat "$out")"
  fi
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "authoritative active run retained paused mode"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "authoritative active run did not resume wedge tracking"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a declared pause is periodically rechecked against authoritative active-run state"
}

test_paused_authoritative_working_preserves_wedge_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case paused-working-preserves-wedge-timer); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-paused-working"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/paused-working.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/paused-working.status"
  sig=$(seen_sig "$state/paused-working.status"); printf '%s' "$sig" > "$state/.seen-paused-working_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "authoritative working state did not start wedge tracking"; }
  since=$(cat "$state/.stale-since-$key")
  sleep 2
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || true)" = "$since" ] \
    || { reap "$pid"; fail "repeat authoritative working recheck reset the wedge timer"; }
  reap "$pid"

  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "authoritative working state did not wedge-escalate past the threshold"
  grep -F "possible wedge" "$out" >/dev/null || fail "authoritative working wedge escalation omitted its reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "wedge timer remained after authoritative working escalation"
  unset FM_FAKE_CREW_STATE
  pass "a paused status overridden by authoritative working preserves its wedge timer and escalates"
}

# --- consecutive wedge escalations on the same pane demand deep inspection ----
# Root cause of the PR #252 incident's ~20 minutes of unnoticed green: each
# wedge escalation fires, gets classified as "still validating" one poll later
# (the timer restarts, see wedge_timer_check), and repeats forever on a pane
# that never changes. A single escalation reason looks identical every round,
# so nothing in the payload itself signals "this has now happened N times in a
# row" - that judgment call was left entirely to the supervisor noticing the
# repetition on its own. This is the safety-net fix: past
# FM_WEDGE_DEMAND_INSPECT_COUNT consecutive escalations on the SAME pane, the
# wake reason itself carries a "demand-deep-inspection" marker.

test_wedge_escalation_marks_demand_deep_inspection_after_threshold() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case wedge-escalation); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged.status"
  sig=$(seen_sig "$state/wedged.status"); printf '%s' "$sig" > "$state/.seen-wedged_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Priming round: first sighting of this stale hash classifies and absorbs it
  # (establishing .stale-$key and starting the wedge timer) without going
  # through wedge_timer_check at all - mirrors the existing wedge tests' Phase A.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited on the priming round (should absorb): $(cat "$out")"
  fi
  reap "$pid"

  n=1
  while [ "$n" -le 3 ]; do
    # Backdate the wedge timer past the threshold before each round, mirroring
    # the existing wedge-escalation tests' Phase B (the subsequent-sight timer
    # path does not re-read the crew state).
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 40 || fail "watcher did not escalate on consecutive wedge round $n: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "escalation counter did not persist across consecutive rounds"
  unset FM_FAKE_CREW_STATE
  pass "consecutive wedge escalations on the same pane accumulate and demand deep inspection at the threshold"
}

test_wedge_escalation_resets_when_pane_becomes_active() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case wedge-escalation-reset); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged-reset"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged-reset.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged-reset.status"
  sig=$(seen_sig "$state/wedged-reset.status"); printf '%s' "$sig" > "$state/.seen-wedged-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Pre-seed one escalation as if a prior wedge round already fired.
  printf '1\n' > "$state/.wedge-escalations-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # The pane content changes (the crew is active again): the hash no longer
  # matches, so the watcher resets escalation bookkeeping instead of escalating.
  printf 'new output, crew active again' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited on a fresh (changed) pane hash: $(cat "$out")"
  fi
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a changed pane hash did not reset the wedge-escalation counter"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a pane becoming active again resets the consecutive wedge-escalation counter"
}

test_nonterminal_stale_repairs_missing_or_corrupt_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case nonterminal-stale-timer-repair); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet-timer"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet-timer.meta"
  printf 'working: still compiling\n' > "$state/quiet-timer.status"
  sig=$(seen_sig "$state/quiet-timer.status"); printf '%s' "$sig" > "$state/.seen-quiet-timer_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with missing timer did not initialize stale-since"; }
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    fail "watcher exited while repairing a missing stale-since timer: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "missing stale-since repair enqueued a wake"; }
  reap "$pid"

  printf 'corrupt\n' > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with corrupt timer did not repair stale-since"; }
  since=$(cat "$state/.stale-since-$key" 2>/dev/null || true)
  [ "$since" != "corrupt" ] || { reap "$pid"; fail "corrupt stale-since value was left in place"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "corrupt stale-since repair enqueued a wake"; }
  reap "$pid"
  pass "matching non-terminal stale suppressors repair missing or corrupt stale-since timers"
}

# --- triage debug log stays size capped -------------------------------------

test_triage_log_size_cap_accepts_spaced_wc_counts() {
  local dir state fakebin out status_file pid lines i
  dir=$(make_case triage-log-spaced-wc); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  i=1
  while [ "$i" -le 3000 ]; do
    printf 'old line %04d\n' "$i" >> "$state/.watch-triage.log"
    i=$((i + 1))
  done
  cat > "$fakebin/wc" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "-c" ]; then
  printf '   999999\n'
  exit 0
fi
exit 127
SH
  chmod +x "$fakebin/wc"
  status_file="$state/task.status"
  printf 'window=fm-task\nkind=ship\n' > "$state/task.meta"
  printf 'working: compiling step 2\n' > "$status_file"
  # Provably working so the no-verb signal is absorbed (which is what writes the
  # triage log line under test).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_TRIAGE_LOG_MAX_BYTES=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a benign signal while testing log capping: $(cat "$out")"
  fi
  i=0
  while [ "$i" -lt 30 ]; do
    lines=$(awk 'END { print NR + 0 }' "$state/.watch-triage.log")
    [ "$lines" -le 2000 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$lines" -le 2000 ] || { reap "$pid"; fail "triage log was not capped when wc emitted a spaced byte count (lines=$lines)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "benign signal enqueued a wake while testing log capping"; }
  reap "$pid"
  pass "triage log capping handles wc byte counts with leading spaces"
}

# --- heartbeat: no-change absorbed, backstop surfaces a missed status --------

test_heartbeat_no_change_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case heartbeat-absorb); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  # A truly quiet fleet (no windows, no statuses) with a fast heartbeat cadence.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a no-change heartbeat (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "no-change heartbeat printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "no-change heartbeat enqueued a durable wake record"
  [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] || fail "heartbeat backoff streak did not advance while absorbing"
  reap "$pid"
  pass "a heartbeat with no captain-relevant change is absorbed and backs off the cadence"
}

test_heartbeat_backstop_surfaces_unsurfaced_status() {
  local dir state fakebin out drain_out sig pid
  dir=$(make_case heartbeat-backstop); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # A captain-relevant status whose .seen-* signature ALREADY matches (so the
  # per-poll signal scan stays quiet) but which was never surfaced (no
  # .hb-surfaced-* marker). This stands in for a per-wake-path miss; the heartbeat
  # fleet-scan backstop must catch it and wake firstmate.
  printf 'done: PR https://example.test/pr/5\n' > "$state/miss.status"
  printf 'window=fm-miss\nkind=ship\n' > "$state/miss.meta"
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "heartbeat backstop did not surface an unsurfaced captain-relevant status"
  grep -Fx "heartbeat" "$out" >/dev/null || fail "backstop did not exit with a heartbeat wake"
  [ "$(cat "$state/.hb-surfaced-miss" 2>/dev/null || true)" = "done: PR https://example.test/pr/5" ] \
    || fail "backstop did not record the status as surfaced (would re-fire next heartbeat)"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the backstop heartbeat failed"
  grep "$(printf '\theartbeat\t')" "$drain_out" >/dev/null || fail "backstop heartbeat was not queued"
  pass "heartbeat backstop fail-safe surfaces a captain-relevant status the per-wake path missed"
}

# --- beacon stays fresh while absorbing -------------------------------------

test_beacon_stays_fresh_while_absorbing() {
  local dir state fakebin out status_file pid m1 m2 now
  dir=$(make_case beacon-fresh); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'window=fm-task\nkind=ship\n' > "$state/task.meta"
  printf 'working: a\n' > "$status_file"
  # Provably working so the working: notes are absorbed (the path that must keep the
  # beacon fresh).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_live "$pid" 15 || { reap "$pid"; fail "watcher exited while absorbing the first benign signal"; }
  m1=$(file_mtime "$state/.last-watcher-beat")
  # A second benign signal keeps it absorbing; the beacon must keep advancing.
  printf 'working: b\n' >> "$status_file"
  wait_live "$pid" 20 || { reap "$pid"; fail "watcher exited while absorbing a second benign signal"; }
  m2=$(file_mtime "$state/.last-watcher-beat")
  now=$(date +%s)
  if [ -z "$m1" ] || [ -z "$m2" ]; then
    reap "$pid"
    fail "watcher beacon missing while absorbing"
  fi
  [ "$m2" -ge "$m1" ] || { reap "$pid"; fail "beacon mtime regressed while absorbing"; }
  [ "$(( now - m2 ))" -lt 10 ] || { reap "$pid"; fail "beacon went stale while absorbing (age $(( now - m2 ))s)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "absorbing benign signals enqueued a wake"; }
  reap "$pid"
  pass "the liveness beacon stays fresh while the watcher absorbs benign wakes (fm-guard never false-alarms)"
}

# --- afk coherence: the daemon owns triage; the watcher does not double-triage ---

test_afk_present_reverts_watcher_to_one_shot() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case afk-coherence); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'window=fm-task\nkind=ship\n' > "$state/task.meta"
  printf 'working: routine note\n' > "$status_file"
  date '+%s' > "$state/.afk"   # away mode: the supervise-daemon owns triage
  # Set a PROVABLY-WORKING verdict: if afk failed to bypass the provably-working
  # check, this no-verb signal would be absorbed (not surfaced). The test asserting
  # a surface therefore also proves afk reverts to one-shot and skips the costly read.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "with .afk present the watcher did not exit one-shot for a benign signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "afk-mode watcher did not surface the signal for the daemon"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the afk-mode signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "afk-mode benign signal was not queued for the daemon to classify"
  pass "with .afk present the watcher reverts to one-shot so the daemon owns triage (no double-triage)"
}

# A paused pane can first appear as a changed hash. In AFK mode that initial path
# must still hand off the plain window identity to the daemon, rather than running
# the normal-mode pause re-surface and decorating the stale identity.
test_afk_paused_changed_pane_hands_off_plain_stale() {
  local dir state fakebin out drain_out capture_file statusf window key sig pid back
  dir=$(make_case afk-paused-changed-pane); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-afk-held"
  printf 'idle, awaiting upstream\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/afk-held.meta"
  statusf="$state/afk-held.status"
  printf 'paused: awaiting the upstream tool release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-held_status"
  date '+%s' > "$state/.afk"
  key=$(printf '%s' "$window" | tr '.:/' '___')

  # Deliberately do not seed .hash-*: this is the changed-pane path that used to
  # call handle_paused_stale before AFK's one-shot daemon handoff.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream tool release' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "AFK paused changed pane did not hand off a stale wake"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "AFK paused stale did not preserve its plain window identity: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null && fail "AFK watcher decorated a stale identity instead of handing it to the daemon"
  [ ! -e "$state/.paused-$key" ] || fail "AFK watcher recorded normal-mode pause tracking instead of handing off"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after AFK paused stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "stale: $window" >/dev/null \
    || fail "AFK paused stale was not queued with the plain window identity"
  pass "AFK changed paused panes hand off plain stale identities for daemon-owned pause triage"
}

test_signal_reason_is_actionable_classifier
test_stale_is_terminal_classifier
test_scan_captain_relevant_statuses_classifier
test_scan_skips_orphaned_status_logs
test_classifier_primitives
test_crew_is_provably_working_classifier
test_status_is_paused_classifier
test_crew_absorb_class_classifier
test_signal_crew_provably_working_classifier
test_signal_reconciliation_detail_precedence
test_signal_reconciliation_detail_frames_each_captain_state
test_signal_reconciliation_detail_reads_the_status_log
test_signal_reconciliation_detail_is_kind_aware
test_signal_reconciliation_detail_uses_the_passed_state
test_endpoint_verdict_ignores_free_text_status_detail
test_provably_working_signal_absorbed
test_turn_ended_provably_working_absorbed
test_turn_ended_not_working_surfaced
test_working_note_not_working_surfaced
test_actionable_signal_surfaced
test_terminal_stale_surfaced
test_stale_terminal_status_overridden_by_active_run
test_nonterminal_stale_provably_working_absorbed_then_escalated
test_wedge_escalation_marks_demand_deep_inspection_after_threshold
test_wedge_escalation_resets_when_pane_becomes_active
test_nonterminal_stale_not_working_surfaced
test_unreadable_endpoint_surfaces_once_per_episode
test_transient_capture_failure_absorbed
test_stale_miss_does_not_pair_with_a_later_blip
test_secondmate_endpoint_wake_names_its_home
test_every_lost_endpoint_surfaces_independently
test_endpoint_wake_not_suppressed_when_the_queue_append_fails
test_endpoint_loss_confirmed_while_siblings_keep_signalling
test_secondmate_unreadable_endpoint_surfaces
test_secondmate_idle_pane_still_absorbed
test_nonterminal_stale_paused_absorbed_then_resurfaced
test_secondmate_paused_resurfaces_in_normal_mode
test_secondmate_nonpaused_stale_remains_suppressed
test_secondmate_unpause_clears_pause_tracking
test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash
test_nonterminal_paused_rechecks_authoritative_state
test_paused_authoritative_working_preserves_wedge_timer
test_nonterminal_stale_repairs_missing_or_corrupt_timer
test_triage_log_size_cap_accepts_spaced_wc_counts
test_heartbeat_no_change_absorbed
test_heartbeat_backstop_surfaces_unsurfaced_status
test_beacon_stays_fresh_while_absorbing
test_afk_present_reverts_watcher_to_one_shot
test_afk_paused_changed_pane_hands_off_plain_stale
