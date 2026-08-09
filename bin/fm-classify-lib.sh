#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, declared-external-wait vocabulary, and the working/paused absorb
# classification that makes no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
#
# The one exception is the absorb classification (crew_absorb_class and its
# working/paused wrappers). It is NOT a pure status-file read: it reuses
# bin/fm-crew-state.sh, which may make a bounded no-mistakes call, to decide
# whether a crew that just stopped its turn or went stale is working, deliberately
# paused, or neither. Callers run it ONLY on no-verb signal handling and first
# sighting of a stale hash, never on every wake, so the per-wake triage stays
# cheap.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared pause. Far longer than the wedge
# threshold (FM_STALE_ESCALATE_SECS, default 240s) so a deliberate wait is not
# nagged like a wedge, yet finite so a forgotten pause cannot rot invisibly - it
# re-surfaces once for a recheck every window. One hour by default; both consumers
# read FM_PAUSE_RESURFACE_SECS with this default so the cadence has one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=3600

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line matches a captain-relevant verb.
status_is_captain_relevant() {
  local line=$1
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 1
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=${line%%:*}
  verb=${verb#"${verb%%[![:space:]]*}"}
  verb=${verb%"${verb##*[![:space:]]}"}
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# Read one canonical current-state line for a crew. Keeping this read separate
# from the parser lets signal reconciliation use the same bounded lookup once per
# task while retaining the full detail needed for a recovery recommendation.
# NOT a pure read: fm-crew-state.sh may make a bounded no-mistakes call, so callers
# run it only on no-verb signal and first-sighting stale paths, never every wake.
# FM_CREW_STATE_BIN lets tests stub the verdict.
crew_state_line() {  # <id>
  local id=$1 line
  [ -n "$id" ] || return 0
  line=$("$FM_CREW_STATE_BIN" --reconcile "$id" 2>/dev/null) || true
  printf '%s\n' "$line" | head -1
}

# 0 when task <id> has no state/<id>.meta under <state>, i.e. the task is GONE
# rather than idle. Asking fm-crew-state.sh about it yields `unknown`, which
# reads as "not provably working" and would surface a wake for a crew that no
# longer exists - the .turn-ended twin of the orphaned-.status problem, since a
# bare turn-end marker carries no verb. An unresolvable state dir is never an
# orphan verdict: absence of evidence is not evidence the task is gone.
task_is_orphan() {  # <state> <id>
  [ -n "$1" ] && [ -d "$1" ] && [ ! -e "$1/$2.meta" ]
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/fm-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci) or a busy
#             pane; the crew is legitimately mid-work on a static-looking pane
#             (e.g. waiting on CI);
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   orphan  - no state/<id>.meta: the task is gone, so the signal is leftover
#             state from a finished task and there is no crew to wake for;
#   none    - none of those, so the wake must surface (a stopped/finished/parked/
#             failed/unknown crew, or an unreadable verdict).
# One fm-crew-state.sh read serves BOTH absorb reasons at once. Reading the state
# authoritatively (not the status log) is what keeps run-step precedence: a crew
# that appended paused: but then STARTED a run reports working, never paused.
# This pure parser is the single mapping from the current-state reader onto that
# working/paused/none vocabulary; crew_absorb_class is the read-plus-parse pair.
crew_absorb_class_from_line() {  # <state-line>
  local line=$1 state src endpoint
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  endpoint=$(crew_state_endpoint_field "$line")
  case "$endpoint" in
    alive) ;;
    gone|unknown) printf 'none'; return ;;
    *) case "$line" in *'endpoint: gone'*|*'endpoint: unknown'*) printf 'none'; return ;; esac ;;
  esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in run-step|pane) printf 'working'; return ;; esac
  fi
  printf 'none'
}

crew_absorb_class() {  # <id> [<state>]
  local id=$1 state_dir=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} line
  [ -n "$id" ] || { printf 'none'; return; }
  # A gone task is absorbed before any live-state read: there is nothing left to
  # wake for, and the read would only report `unknown`.
  if task_is_orphan "$state_dir" "$id"; then printf 'orphan'; return; fi
  line=$(crew_state_line "$id")
  crew_absorb_class_from_line "$line"
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-when-provably-working: a no-verb turn-end or stale wake is absorbed
# ONLY when this returns 0, and SURFACED otherwise (the crew may be done, waiting
# on a decision, or wedged). For stale panes it is checked before trusting the
# status log so a pre-validation captain-relevant line does not override an active
# run. See crew_absorb_class for the exact working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# The recorded kind of a task, or `unknown` when it has no readable metadata.
task_kind() {  # <state> <task>
  local kind
  [ -n "$1" ] && [ -e "$1/$2.meta" ] || { printf 'unknown'; return; }
  kind=$(grep '^kind=' "$1/$2.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  printf '%s' "${kind:-ship}"
}

# The recovery clause for a confirmed lost endpoint. Every detector emits the
# same guidance for the same kind of direct report, so the wording lives here
# once: a secondmate has no task worktree - its metadata records a home, and it
# is recovered by relaunching there - while a crewmate may simply have finished.
endpoint_recovery_advice() {  # <kind>
  if [ "$1" = secondmate ]; then
    printf 'relaunch it in its recorded firstmate home, then continue supervision'
  else
    printf 'resume or relaunch from recorded metadata and worktree unless that last report shows the work already landed, then continue supervision'
  fi
}

# Describe the recovery action for a no-verb signal whose crew is neither
# provably working nor deliberately paused. The caller already performed one
# bounded current-state read, so this is a formatting decision over that evidence
# plus two cheap reads of the task's own recorded files. It deliberately carries
# the task id and distinguishes a lost endpoint from a live idle endpoint,
# recognising endpoint loss through the same crew_state_endpoint_lost predicate
# that picks the endpoint-lost class, so the prose and the class can never
# disagree about what this line reports.
signal_reconciliation_detail() {  # <state> <id> <state-line> <turn-end|status-signal>
  local sdir=$1 task=$2 line=$3 context=$4 state phrase last
  # "no terminal status" is a claim about the TASK, not about which files the
  # wake happened to name, so it has to be read from the status log. A crew that
  # reported done before the daemon started has no seen-status marker yet, and
  # asserting it never reported would point away mode at relaunching finished
  # work.
  last=$(last_status_line "$sdir/$task.status")
  if [ "$context" = turn-end ]; then
    phrase='after turn end'
  else
    phrase='after a no-verb status wake'
  fi
  if [ -z "$last" ] || ! status_is_captain_relevant "$last"; then
    phrase="$phrase with no terminal status"
  fi
  state=${line#state: }; state=${state%% *}
  # Endpoint loss outranks everything: it is the one fact that makes the rest of
  # the read unreliable, whatever state it reports.
  if crew_state_endpoint_lost "$line"; then
    printf 'task %s endpoint gone %s (%s); last reported: %s; recommended recovery: %s' \
      "$task" "$phrase" "${line:-state unreadable}" "${last:-no status}" \
      "$(endpoint_recovery_advice "$(task_kind "$sdir" "$task")")"
    return
  fi
  case "$line" in
    *'no backend target recorded'*|*'no metadata for '*|*'worktree gone'*)
      printf 'task %s has incomplete recorded state %s (%s); recommended recovery: reconcile its metadata and worktree before resume or safe teardown' \
        "$task" "$phrase" "${line:-state unreadable}"
      return
      ;;
  esac
  # The reported STATE outranks the source it came from. A checks-green crew
  # monitoring its PR reports done from the status log, and describing that as an
  # unfinished task to continue would contradict the very line it quotes - and
  # away mode acts on this text, not on operator prose.
  if [ "$state" = done ]; then
    printf 'task %s reports done %s (%s); recommended action: record completion and continue the existing delivery or safe teardown path' \
      "$task" "$phrase" "${line:-state unreadable}"
    return
  fi
  case "$line" in
    *'source: status-log'*|*'no current-state source available'*)
      printf 'task %s endpoint alive but idle %s (%s); recommended action: inspect and continue the unfinished task' \
        "$task" "$phrase" "${line:-state unreadable}"
      return
      ;;
  esac
  printf 'task %s needs reconciliation %s (%s); recommended action: inspect live state and continue or recover the task' \
    "$task" "$phrase" "${line:-state unreadable}"
}

# Map one wake file onto the task it belongs to. Prints nothing for a path that
# is not a per-task signal file.
signal_file_task() {  # <file>
  local base=${1##*/}
  case "$base" in
    *.status)     printf '%s' "${base%.status}" ;;
    *.turn-ended) printf '%s' "${base%.turn-ended}" ;;
  esac
}

# The home that owns a task's signal file in this wake: the directory of the
# first per-task signal file naming it, falling back to the ambient state dir for
# a bare filename. A wake reason can carry an absolute path from another
# firstmate home, so liveness has to be judged against the home that actually
# owns the task rather than whichever state dir this process happens to hold.
signal_task_state_dir() {  # <task> <file> ...
  local task=$1 f
  shift
  for f in "$@"; do
    [ "$(signal_file_task "$f")" = "$task" ] || continue
    case "$f" in */*) printf '%s' "${f%/*}"; return ;; esac
    break
  done
  printf '%s' "${STATE:-${FM_STATE_OVERRIDE:-}}"
}

# Reduce a wake's file list to one "<task><TAB><turn-end|status-signal>" record
# per unique task, in first-seen order. A task whose turn-end marker is part of
# the same wake reports turn-end context, because that is the shape the incident
# is described from. This is the shared fan-in for every per-task reconciliation
# consumer below, so the wake-to-task mapping has exactly one definition.
signal_wake_tasks() {  # <file> ...
  local f task seen="" turn_ended=""
  for f in "$@"; do
    task=$(signal_file_task "$f")
    [ -n "$task" ] || continue
    case "${f##*/}" in
      *.turn-ended) case " $turn_ended " in *" $task "*) ;; *) turn_ended="$turn_ended $task" ;; esac ;;
    esac
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
  done
  for task in $seen; do
    case " $turn_ended " in
      *" $task "*) printf '%s\t%s\n' "$task" turn-end ;;
      *)           printf '%s\t%s\n' "$task" status-signal ;;
    esac
  done
}

# The value of the dedicated trailing `endpoint:` field bin/fm-crew-state.sh
# appends in --reconcile mode, or nothing when the line carries no such field
# (the default operator read). Taking the LAST occurrence is what makes the
# appended field authoritative: a crew's own status note can mention an endpoint
# in its free text, and that text must never decide the endpoint verdict.
crew_state_endpoint_field() {  # <state-line>
  local tail
  case "$1" in *'endpoint: '*) ;; *) return 0 ;; esac
  tail=${1##*endpoint: }
  printf '%s' "${tail%% *}"
}

# 0 when a current-state line reports the crew's ENDPOINT as lost, as opposed to
# any other actionable condition. Endpoint loss is the one condition several
# supervision detectors can observe independently, so naming it here keeps the
# recognition in the classifier instead of leaving each consumer to guess it from
# the recovery prose it happens to have been handed. The authoritative field wins
# outright; the free-text patterns are only the fallback for a line that has no
# such field.
crew_state_endpoint_lost() {  # <state-line>
  case "$(crew_state_endpoint_field "$1")" in
    gone)  return 0 ;;
    alive) return 1 ;;
    unknown) return 1 ;;
  esac
  case "$1" in
    *'endpoint: gone'*|*'backend target gone:'*) return 0 ;;
  esac
  return 1
}

# Reconcile ONE task with exactly one bounded fm-crew-state.sh read and print
# "<working|paused|orphan|endpoint-lost|actionable>|<detail>". This is the single
# per-task decision every reconciliation consumer shares: the aggregate below,
# and the away-mode daemon, which needs per-task granularity to apply its
# escalation dedupe without a second live-state read. `endpoint-lost` is an
# actionable sub-class - the fold treats it exactly like `actionable` - reported
# separately so a consumer can recognise the shared condition without parsing the
# human-facing detail text. `orphan` is the opposite: a task with no recorded
# metadata is gone, so its leftover signal is absorbed without a live-state read.
crew_signal_reconciliation() {  # <state> <task> [turn-end|status-signal]
  local sdir=$1 task=$2 context=${3:-status-signal} line class
  if [ -z "$task" ]; then
    printf 'actionable|signal did not resolve a task; recommended action: inspect the queued wake and reconcile its task metadata'
    return
  fi
  # A gone task is settled before any live-state read: there is nothing to
  # reconcile and no crew left to wake for.
  if task_is_orphan "$sdir" "$task"; then
    printf 'orphan|task %s is gone (no recorded metadata); its leftover signal has nothing to wake for' "$task"
    return
  fi
  line=$(crew_state_line "$task")
  class=$(crew_absorb_class_from_line "$line")
  case "$class" in
    working) printf 'working|task %s is provably working (%s)' "$task" "${line:-state unreadable}" ;;
    paused)  printf 'paused|task %s is in a declared external pause (%s)' "$task" "${line:-state unreadable}" ;;
    *)
      if crew_state_endpoint_lost "$line"; then
        printf 'endpoint-lost|%s' "$(signal_reconciliation_detail "$sdir" "$task" "$line" "$context")"
      else
        printf 'actionable|%s' "$(signal_reconciliation_detail "$sdir" "$task" "$line" "$context")"
      fi ;;
  esac
}

# Reconcile every unique task referenced by a no-verb signal using exactly one
# fm-crew-state.sh read per task. This is the ONE fold from per-task decisions
# onto a wake-level verdict; every consumer goes through it rather than keeping
# its own copy of the precedence rule. Prints one decision record:
#   working|...    every task has positive active-work evidence, or is gone;
#   paused|...     every task is absorbable and at least one is deliberately paused;
#   actionable|... at least one task stopped, lost its endpoint, or is uncertain;
#   seen|...       actionable, but the caller's hook reported every detail already
#                  covered, so there is nothing new to surface.
# The actionable detail includes each affected task id and the recommended next
# step so away-mode batching can surface a useful recovery instruction without a
# second live-state read.
#
# FM_RECONCILE_TASK_HOOK is the caller's bookkeeping seam: when set to a function
# name it is invoked as `<hook> <task> <class> <detail>` for every reconciled
# task, and its stdout replaces the detail carried for an actionable task. Empty
# stdout means the caller already covered that task (its own dedupe), which is
# what turns an all-covered verdict into `seen`. The hook owns persistence only;
# the classification and the fold stay here.
signal_crew_reconciliation() {  # <state> <file> ...
  local sdir=$1; shift
  local task context rec class detail hooked seen="" details="" covered="" overall=working
  while IFS="$(printf '\t')" read -r task context; do
    [ -n "$task" ] || continue
    seen="$seen $task"
    rec=$(crew_signal_reconciliation "$sdir" "$task" "$context")
    class=${rec%%|*}; detail=${rec#*|}
    # A gone task is absorbed without reaching the caller's bookkeeping: there is
    # nothing to dedupe against and nothing left to escalate.
    if [ "$class" = orphan ]; then continue; fi
    if [ -n "${FM_RECONCILE_TASK_HOOK:-}" ]; then
      hooked=$("$FM_RECONCILE_TASK_HOOK" "$task" "$class" "$detail")
    else
      hooked=$detail
    fi
    case "$class" in
      working) ;;
      paused)  [ "$overall" = actionable ] || overall=paused ;;
      *)
        overall=actionable
        if [ -n "$hooked" ]; then
          details="${details}${details:+ | }${hooked}"
        else
          covered="${covered}${covered:+ | }${detail}"
        fi ;;
    esac
  done <<<"$(signal_wake_tasks "$@")"
  if [ -z "$seen" ]; then
    printf 'actionable|signal did not resolve a task; recommended action: inspect the queued wake and reconcile its task metadata'
    return
  fi
  case "$overall" in
    working) printf 'working|all referenced tasks are provably working or gone:%s' "$seen" ;;
    paused)  printf 'paused|all referenced tasks are working or in a declared external pause:%s' "$seen" ;;
    *)       if [ -n "$details" ]; then printf 'actionable|%s' "$details"
             else printf 'seen|%s' "$covered"; fi ;;
  esac
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is
# provably working or gone; 1 (actionable/surface) if any is paused, stopped,
# uncertain, or cannot be resolved. A normal-mode declared pause intentionally
# surfaces its initial signal; away mode consumes the richer per-task decisions
# above and tracks the bounded pause recheck.
# The always-on watcher only needs the boolean, so this stops at the first task
# that is not absorbable rather than paying a bounded live-state read for every
# remaining task in the wake.
signal_crew_provably_working() {  # <file> ...
  local task context resolved=""
  while IFS="$(printf '\t')" read -r task context; do
    [ -n "$task" ] || continue
    resolved=1
    case "$(crew_absorb_class "$task" "$(signal_task_state_dir "$task" "$@")")" in
      working|orphan) ;;
      *) return 1 ;;
    esac
  done <<<"$(signal_wake_tasks "$@")"
  [ -n "$resolved" ]
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant AND whose task is still live. This is the cheap fleet-scan both
# supervisors run as a catch-all backstop for a captain-relevant status the
# per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
#
# Liveness is the presence of the task's state/<id>.meta. A status log with no
# meta is an ORPHAN: its task is gone, so its terminal `done:`/`blocked:` line is
# settled history, not news, and re-reporting it wastes a captain escalation on
# work that already finished. bin/fm-teardown.sh archives the log out of state/ on
# a clean teardown, so this guard is the backstop for logs orphaned another way.
#
# THIS GUARD TREATS A SYMPTOM. What actually produces orphans is NOT identified;
# do not read it as closed. A teardown that failed partway is ruled out - teardown
# removes .status and .meta in one rm, and every earlier abort leaves the meta in
# place, so a partial teardown yields meta+status, never status alone. What has
# been observed is agents outside firstmate's meta bookkeeping: a live `fm-<id>`
# pane with no state files at all, whose next status append creates an orphan by
# construction. Whether that comes from killed panes, crashed lanes, or writes
# outside the brief protocol is unknown, so this guard must not be the last word.
#
# There is no live-task race to lose: bin/fm-spawn.sh writes the meta before the
# agent can append its first status line, so meta always precedes status.
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    [ -e "$state/$task.meta" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
