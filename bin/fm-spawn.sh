#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse or Orca worktree, or a
# secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] [--scout]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] --secondmate
#   --harness <name> is the explicit per-spawn harness/profile adapter. The old
#   positional harness arg still works for back-compat.
#   --model <name> and --effort <low|medium|high|xhigh|max> are concrete profile
#   axes chosen by firstmate at intake. They are only threaded into harnesses whose
#   installed CLIs were verified to support that axis; an omitted axis is never
#   dropped silently - it warns on stderr naming the harness, model, effort, and
#   reason. Per-harness effort flags and their dated CLI evidence are recorded in
#   .agents/skills/harness-adapters/SKILL.md.
#   codex effort is the one PER-MODEL axis, and this script owns that contract.
#   `codex debug models` advertises supported_reasoning_levels per model, so the
#   script resolves the EFFECTIVE model - the explicit --model when set, else the
#   top-level `model` key in $CODEX_HOME/config.toml (default ~/.codex/config.toml);
#   a `profile =` selection leaves it unresolved - and reads that model's advertised
#   levels from the installed CLI rather than a hard-coded model list. low, medium,
#   high, and xhigh are advertised by every catalog model, so they still pass when
#   the catalog cannot be read. max is the level the catalog splits on, so it is
#   passed only when the effective model advertises it, and is otherwise omitted
#   with a warning - including when no effective model resolves - rather than
#   reaching a launch that cannot honor it. ultra is never passed: codex defines it
#   as maximum reasoning with automatic task delegation, which is outside
#   firstmate's supervised crewmate lifecycle, and it is untested here.
#   A RAW launch command is the one axis-threading exception: firstmate runs it
#   verbatim, so neither --model nor --effort can reach it. Both are then ignored
#   with an explicit stderr warning and the spawn continues rather than erroring,
#   because refusing would break the escape hatch's whole purpose - launching an
#   unverified adapter by hand, where the raw command already carries whatever
#   model and effort flags that adapter wants.
#   --backend <name> is the explicit runtime session-provider backend for this
#   spawn. Without it, the script resolves FM_BACKEND, then config/backend, then
#   runtime auto-detection (the runtime firstmate itself is executing inside -
#   $TMUX, HERDR_ENV=1, or cmux runtime signals; bin/fm-backend.sh's
#   fm_backend_detect, with cmux fallback details in docs/cmux-backend.md),
#   then tmux.
#   Spawn-capable backends are the reference tmux adapter and experimental
#   herdr, zellij, orca, and cmux. Orca owns both the task worktree and
#   terminal, so ship/scout Orca spawns do not run treehouse get; cmux is a
#   session provider only, exactly like herdr/zellij, so it does. An
#   auto-detected herdr or cmux spawn prints a loud stderr notice;
#   auto-detected tmux stays silent; zellij and orca are never auto-detected.
#   codex-app is not a known backend yet; docs/codex-app-backend.md owns that
#   blocked backend contract. Default tmux spawns do not write backend= to meta;
#   absent backend= means tmux. cmux does not support --secondmate spawns yet.
#   A backend spawn refusal (missing dependency, version gate, unauthenticated
#   socket, or unsupported secondmate mode) is terminal for that selected backend;
#   callers must surface it instead of silently retrying another backend.
#   With no harness arg, a crewmate/scout spawn resolves the CREW harness only when
#   config/crew-dispatch.json is absent. When that file exists, crewmate/scout
#   spawns require an explicit harness so firstmate cannot silently skip dispatch
#   profile consultation. A --secondmate spawn is exempt and resolves the SECONDMATE
#   harness (config/secondmate-harness -> config/crew-harness -> own), so the
#   secondmate-vs-crewmate split is DURABLE across every respawn (recovery,
#   /updatefirstmate, restart). A bare adapter name (claude|codex|opencode|pi|grok)
#   overrides it for this spawn (either kind). A non-flag string containing
#   whitespace is treated as a RAW launch command - the escape hatch for verifying
#   new adapters.
#   config/secondmate-harness may also carry an optional model and effort as extra
#   whitespace-separated tokens ("<harness> [<model>] [<effort>]"). For a
#   --secondmate spawn, those tokens apply only when this spawn also resolves its
#   harness from config/secondmate-harness. An explicit per-spawn --harness,
#   positional harness arg, or raw launch command starts with clean model/effort
#   defaults unless the caller also passes explicit --model/--effort flags - which a
#   raw launch records in meta but still ignores at launch, per the exception above. When
#   the file governs the spawn, its model/effort tokens are re-resolved on every
#   respawn exactly like the harness axis, and explicit --model/--effort flags
#   still win over the file's tokens.
#   A --secondmate spawn also propagates the primary's declared inheritable config
#   into the secondmate home's config/, so the secondmate's OWN crewmates,
#   dispatch profiles, and backlog backend inherit the primary's settings
#   (fm-config-inherit-lib.sh).
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md task lifecycle); --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home; the default is kind=ship.
#   Reusing an existing task id adopts the recorded worktree before any fresh treehouse
#   acquisition. The recorded backend endpoint and every matching task meta are checked first;
#   a live or ambiguous agent holder refuses the spawn, while a missing recorded worktree warns
#   that WIP or a checked-out branch may remain before requesting a fresh treehouse worktree.
#   No branch is detached automatically when the recorded worktree is missing or unavailable.
#   Before a secondmate launch, the home is locally fast-forwarded to the primary
#   default-branch commit when safe; skipped syncs warn and launch unchanged.
#   Ship/scout spawns refuse to launch unless the resolved task path is a real
#   git worktree root distinct from the primary project checkout. Treehouse-backed
#   spawns additionally require the task worktree and requested project to share
#   the same canonical Git common directory; Orca keeps its adapter-owned clone
#   contract and is subject only to the backend-safe isolation check.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; shared --scout/--harness/--model/--effort/--backend applies to every pair.
#   If config/crew-dispatch.json exists, shared --harness is required for crewmate
#   and scout batches. The loop lives here, in bash, so callers never hand-write a
#   multi-task shell loop (the tool shell is zsh, which does not word-split unquoted
#   $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
#     __PITURNEND__ absolute path to .pi/extensions/fm-primary-turnend-guard.ts in a pi secondmate home
#     __PIWATCH__   absolute path to .pi/extensions/fm-primary-pi-watch.ts in a pi secondmate home
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a gitignored .fm-grok-turnend worktree pointer and a state token.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<backend-target> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, and projects=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,100p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-resource-lib.sh
. "$SCRIPT_DIR/fm-resource-lib.sh"
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
HARNESS_ARG=
MODEL=
EFFORT=
BACKEND_ARG=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
BACKEND_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      harness) HARNESS_ARG=$a; HARNESS_SET=1 ;;
      model) MODEL=$a; MODEL_SET=1 ;;
      effort) EFFORT=$a; EFFORT_SET=1 ;;
      backend) BACKEND_ARG=$a; BACKEND_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --harness) want_value=harness ;;
    --harness=*) HARNESS_ARG=${a#--harness=}; HARNESS_SET=1 ;;
    --model) want_value=model ;;
    --model=*) MODEL=${a#--model=}; MODEL_SET=1 ;;
    --effort) want_value=effort ;;
    --effort=*) EFFORT=${a#--effort=}; EFFORT_SET=1 ;;
    --backend) want_value=backend ;;
    --backend=*) BACKEND_ARG=${a#--backend=}; BACKEND_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || { echo "error: --harness requires a non-empty value" >&2; exit 1; }
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || { echo "error: --model requires a non-empty value" >&2; exit 1; }
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || { echo "error: --effort requires a non-empty value" >&2; exit 1; }
[ "$BACKEND_SET" -eq 0 ] || [ -n "$BACKEND_ARG" ] || { echo "error: --backend requires a non-empty value" >&2; exit 1; }
case "$EFFORT" in
  ''|low|medium|high|xhigh|max) ;;
  *) echo "error: --effort must be one of low, medium, high, xhigh, max" >&2; exit 1 ;;
esac

# Backend selection (data/fm-backend-design-d7): explicit --backend, else
# FM_BACKEND env, else config/backend, else runtime auto-detection, else
# default tmux (fm_backend_name). fm_backend_validate_spawn refuses unknown or
# non-spawn-capable backends. The resolved value is
# recorded in meta only when it is NOT tmux (fm-teardown.sh and fm-watch.sh's
# window_backend/fm_backend_of_meta already treat an absent backend= as tmux),
# so the default path's meta stays byte-identical.
if [ "$BACKEND_SET" -eq 1 ]; then
  BACKEND=$BACKEND_ARG
else
  BACKEND=$(fm_backend_name)
fi
fm_backend_validate_spawn "$BACKEND" || exit 1
fm_backend_source "$BACKEND" || exit 1
if [ "$BACKEND" = orca ] && [ "$KIND" = secondmate ]; then
  echo "error: backend=orca does not support --secondmate spawns yet" >&2
  exit 1
fi
if [ "$BACKEND" = cmux ] && [ "$KIND" = secondmate ]; then
  echo "error: backend=cmux does not support --secondmate spawns yet" >&2
  exit 1
fi
if [ "$BACKEND" = orca ]; then
  fm_backend_orca_runtime_check || exit 1
fi
ORCA_ABORT_CLEANUP=0
ORCA_WORKTREE_ID=
ORCA_TERMINAL=
SPAWN_LOCK=

release_spawn_lock() {
  local lock=$SPAWN_LOCK
  [ -n "$lock" ] || return 0
  rm -f "$lock/pid" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null || true
  SPAWN_LOCK=
}

parse_orca_worktree_result() {
  local raw=$1 rest
  ORCA_WORKTREE_ID=${raw%%$'\t'*}
  if [ "$raw" = "$ORCA_WORKTREE_ID" ]; then
    WT=
    ORCA_TERMINAL=
    return 1
  fi
  rest=${raw#*$'\t'}
  WT=${rest%%$'\t'*}
  if [ "$rest" != "$WT" ]; then
    ORCA_TERMINAL=${rest#*$'\t'}
  else
    ORCA_TERMINAL=
  fi
}

orca_spawn_abort_cleanup() {
  local status=$?
  release_spawn_lock
  [ "$ORCA_ABORT_CLEANUP" = 1 ] || return "$status"
  ORCA_ABORT_CLEANUP=0
  if [ -n "${ORCA_TERMINAL:-}" ]; then
    fm_backend_kill orca "$ORCA_TERMINAL" 2>/dev/null || true
  fi
  if [ -n "${ORCA_WORKTREE_ID:-}" ]; then
    if ! fm_backend_remove_worktree orca "$ORCA_WORKTREE_ID" 2>/dev/null; then
      mkdir -p "$STATE" 2>/dev/null || true
      if [ -d "$STATE" ]; then
        {
          echo "window=$W"
          echo "worktree=${WT:-}"
          echo "project=$PROJ_ABS"
          echo "harness=$HARNESS"
          echo "kind=$KIND"
          echo "mode=${MODE:-no-mistakes}"
          echo "yolo=${YOLO:-off}"
          echo "tasktmp=${TASK_TMP:-}"
          echo "model=${MODEL:-default}"
          echo "effort=${EFFORT:-default}"
          echo "backend=orca"
          echo "orca_worktree_id=$ORCA_WORKTREE_ID"
          [ -z "${ORCA_TERMINAL:-}" ] || echo "terminal=$ORCA_TERMINAL"
        } > "$STATE/$ID.meta" 2>/dev/null || true
      fi
    fi
  fi
  return "$status"
}
trap orca_spawn_abort_cleanup EXIT

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac; then
  if [ "$KIND" != secondmate ] && [ -z "$HARNESS_ARG" ] && [ -f "$CONFIG/crew-dispatch.json" ]; then
    echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
    exit 1
  fi
  rc=0
  shared_args=()
  [ -z "$HARNESS_ARG" ] || shared_args+=(--harness "$HARNESS_ARG")
  [ -z "$MODEL" ] || shared_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || shared_args+=(--effort "$EFFORT")
  [ -z "$BACKEND_ARG" ] || shared_args+=(--backend "$BACKEND_ARG")
  for pair in "${POS[@]}"; do
    case "$pair" in
      *=*) : ;;
      *) echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2; rc=2; continue ;;
    esac
    if [ "$KIND" = secondmate ]; then
      echo "error: batch dispatch does not support --secondmate; spawn each secondmate explicitly" >&2
      rc=2
      continue
    elif [ "$KIND" = scout ]; then
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" ${shared_args[@]+"${shared_args[@]}"} --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" ${shared_args[@]+"${shared_args[@]}"}; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  exit "$rc"
fi
ID=${POS[0]}
PROJ=
ARG3=
FIRSTMATE_HOME=

if [ "$KIND" = secondmate ]; then
  case "${POS[1]:-}" in
    ''|claude|codex|opencode|pi|grok)
      ARG3=${POS[1]:-}
      ;;
    *' '*)
      if [ "${#POS[@]}" -gt 2 ] || [ -d "${POS[1]}" ]; then
        FIRSTMATE_HOME=${POS[1]}
        ARG3=${POS[2]:-}
      else
        ARG3=${POS[1]}
      fi
      ;;
    *)
      FIRSTMATE_HOME=${POS[1]}
      ARG3=${POS[2]:-}
      ;;
  esac
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi
[ -z "$HARNESS_ARG" ] || ARG3=$HARNESS_ARG

acquire_spawn_lock() {
  local lock=$1 old_pid
  mkdir -p "$STATE"
  if mkdir "$lock" 2>/dev/null; then
    SPAWN_LOCK=$lock
    printf '%s\n' "$$" > "$SPAWN_LOCK/pid" || {
      release_spawn_lock
      echo "error: could not record the spawn lock for task $ID; refusing to launch" >&2
      return 1
    }
    return 0
  fi
  old_pid=$(cat "$lock/pid" 2>/dev/null || true)
  case "$old_pid" in
    ''|*[!0-9]*)
      echo "error: spawn lock for task $ID exists without a verifiable owner; refusing to launch" >&2
      return 1
      ;;
  esac
  if kill -0 "$old_pid" 2>/dev/null; then
    echo "error: another spawn for task $ID is in progress (pid $old_pid); refusing to launch" >&2
    return 1
  fi
  rm -f "$lock/pid" 2>/dev/null || {
    echo "error: stale spawn lock for task $ID could not be cleared; refusing to launch" >&2
    return 1
  }
  rmdir "$lock" 2>/dev/null || {
    echo "error: spawn lock for task $ID is not safely removable; refusing to launch" >&2
    return 1
  }
  if ! mkdir "$lock" 2>/dev/null; then
    echo "error: another spawn claimed task $ID while its stale lock was cleared; refusing to launch" >&2
    return 1
  fi
  SPAWN_LOCK=$lock
  printf '%s\n' "$$" > "$SPAWN_LOCK/pid" || {
    release_spawn_lock
    echo "error: could not record the spawn lock for task $ID; refusing to launch" >&2
    return 1
  }
}

[ -n "$ID" ] || { echo "error: missing task id" >&2; exit 2; }
acquire_spawn_lock "$STATE/$ID.spawn.lock" || exit 1

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in the harness-adapters skill.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # firstmate captures the pane (see the harness-adapters skill). It is a per-launch env
    # prefix scoped to this firstmate-launched agent; it never touches the captain's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in fm-tmux-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(cat __BRIEF__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(cat __BRIEF__)"' ;;
    pi)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(cat __BRIEF__)"'
      else
        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(cat __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed below (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(cat __BRIEF__)"' ;;
    *) return 1 ;;
  esac
}

RAW_LAUNCH=0
case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    RAW_LAUNCH=1
    HARNESS=""
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    # A raw command carries no __MODELFLAG__/__EFFORTFLAG__ placeholders, so the
    # profile axes cannot be threaded into it. Warn and continue per this script's
    # header contract; erroring would break the escape hatch this branch exists for.
    if [ -n "$MODEL" ] && [ "$MODEL" != default ]; then
      echo "warning: ignoring --model $MODEL: the raw launch command controls the entire launch, so firstmate adds no model flag" >&2
    fi
    if [ -n "$EFFORT" ] && [ "$EFFORT" != default ]; then
      echo "warning: ignoring --effort $EFFORT: the raw launch command controls the entire launch, so firstmate adds no effort flag" >&2
    fi
    ;;
  '')
    # No explicit harness: resolve from config. A secondmate AGENT launches on the
    # secondmate harness (config/secondmate-harness -> config/crew-harness -> own);
    # every other kind uses the crew harness only when no dispatch profile file is
    # active. Resolving here on every spawn is what makes the split DURABLE - a
    # respawn (recovery, /updatefirstmate, restart) re-resolves, so
    # config/secondmate-harness keeps governing secondmate launches across restarts.
    # The launch_template lookup below is the unverified-adapter guard for both
    # kinds: a harness with no template aborts the spawn.
    if [ "$KIND" = secondmate ]; then
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" secondmate)
      harness_src='config/secondmate-harness (falling back to config/crew-harness)'
    else
      if [ -f "$CONFIG/crew-dispatch.json" ]; then
        echo "error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped)." >&2
        exit 1
      fi
      HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
      harness_src='config/crew-harness'
    fi
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (from $harness_src or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac

# config/secondmate-harness may carry optional model/effort tokens alongside the
# harness ("<harness> [<model>] [<effort>]"). They apply only when this is a
# --secondmate spawn and no explicit per-spawn harness/raw launch was supplied, so
# the harness itself came from the secondmate config fallback chain. Resolving
# here on every spawn makes the pin durable across respawns. Precedence: explicit
# --model/--effort flags still win over the file's tokens.
if [ "$KIND" = secondmate ] && [ -z "$ARG3" ]; then
  if [ "$MODEL_SET" -eq 0 ]; then
    SM_MODEL=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model)
    [ -z "$SM_MODEL" ] || MODEL=$SM_MODEL
  fi
  if [ "$EFFORT_SET" -eq 0 ]; then
    SM_EFFORT=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort)
    if [ -n "$SM_EFFORT" ]; then
      case "$SM_EFFORT" in
        low|medium|high|xhigh|max) EFFORT=$SM_EFFORT ;;
        *) echo "warning: config/secondmate-harness effort token '$SM_EFFORT' is not one of low, medium, high, xhigh, max; ignoring" >&2 ;;
      esac
    fi
  fi
fi

secondmate_registry_value() {
  local id=$1 key=$2 reg line value
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: [^;)]*; scope: [^;)]*; projects: \([^;)]*\); added .*/\1/p') ;;
    *) return 1 ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|grok)
      printf -- '--model %s ' "$(shell_quote "$model")"
      ;;
  esac
}

warn_unsupported_effort() {
  local harness=$1 model=$2 effort=$3 reason=$4
  printf 'warning: omitting %s effort %s for model %s: %s\n' \
    "$harness" "$effort" "${model:-default}" "$reason" >&2
}

# Prints the effective codex model per this script's header contract, or nothing
# when it does not resolve. Always succeeds; callers treat empty as unknown.
codex_effective_model() {
  local model=$1 cfg toplevel
  if [ -n "$model" ] && [ "$model" != default ]; then
    printf '%s\n' "$model"
    return 0
  fi
  cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
  [ -f "$cfg" ] || return 0
  toplevel=$(sed -n '/^[[:space:]]*\[/q;p' "$cfg") || toplevel=
  ! printf '%s\n' "$toplevel" | grep -Eq '^[[:space:]]*profile[[:space:]]*=' || return 0
  printf '%s\n' "$toplevel" \
    | sed -n \
      -e 's/^[[:space:]]*model[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
      -e "s/^[[:space:]]*model[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" \
    | head -1
  return 0
}

# Prints the given model's comma-joined supported_reasoning_levels from the
# installed CLI's catalog, or nothing when it cannot be read (codex or jq absent,
# command failure, model unknown or not listed). Always succeeds; callers treat
# empty as unknown, which this script's header contract defines the handling for.
codex_model_reasoning_levels() {
  local model=$1 catalog
  [ -n "$model" ] || return 0
  command -v codex >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # Bound the catalog read wherever a timeout tool exists: timeout, gtimeout, or
  # a perl alarm covers Linux and stock macOS. With none of the three available
  # the read runs unbounded, the same degrade bin/fm-crew-state.sh accepts.
  if command -v timeout >/dev/null 2>&1; then
    catalog=$(timeout 10 codex debug models 2>/dev/null) || catalog=
  elif command -v gtimeout >/dev/null 2>&1; then
    catalog=$(gtimeout 10 codex debug models 2>/dev/null) || catalog=
  elif command -v perl >/dev/null 2>&1; then
    catalog=$(perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' 10 codex debug models 2>/dev/null) || catalog=
  else
    catalog=$(codex debug models 2>/dev/null) || catalog=
  fi
  [ -n "$catalog" ] || return 0
  printf '%s' "$catalog" \
    | jq -r --arg m "$model" '.models[]? | select(.slug == $m)
        | [.supported_reasoning_levels[]?.effort] | join(",")' 2>/dev/null \
    | head -1
  return 0
}

effort_flag_for_harness() {
  local harness=$1 model=$2 effort=$3 levels eff_model
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
        *) warn_unsupported_effort "$harness" "$model" "$effort" "outside firstmate's effort axis low,medium,high,xhigh,max" ;;
      esac
      ;;
    codex)
      # Verified 2026-08-13 with codex-cli 0.147.0. The per-model gate below,
      # including why ultra is never passed, is specified in this script's header.
      case "$effort" in
        low|medium|high|xhigh|max)
          eff_model=$(codex_effective_model "$model") || eff_model=
          levels=$(codex_model_reasoning_levels "$eff_model") || levels=
          if [ -n "$levels" ]; then
            case ",$levels," in
              *",$effort,"*) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
              *) warn_unsupported_effort "$harness" "$eff_model" "$effort" "codex debug models advertises only $levels for this model" ;;
            esac
          elif [ "$effort" = max ]; then
            warn_unsupported_effort "$harness" "$eff_model" "$effort" "the effective model's advertised reasoning levels are unknown, so max cannot be confirmed"
          else
            printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")"
          fi
          ;;
        *) warn_unsupported_effort "$harness" "$model" "$effort" "outside firstmate's codex effort axis low,medium,high,xhigh,max" ;;
      esac
      ;;
    grok)
      # Recheck attempted 2026-08-13: `command -v grok` and `grok --version`
      # both reported command not found, so retain the prior verified 0.2.73 gate.
      # Grok's profile axis is reasoning effort, and prior verification rejected max.
      case "$effort" in
        low|medium|high|xhigh) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
        *) warn_unsupported_effort "$harness" "$model" "$effort" "grok 0.2.73 rejects --reasoning-effort $effort" ;;
      esac
      ;;
    pi)
      # Verified 2026-08-13 with pi 0.83.0 using `pi --version` and `pi --help`.
      # `pi --thinking max --offline --no-session --no-tools -p ...` reached model setup
      # and returned only the expected missing-API-key error, while ultra was rejected.
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
        *) warn_unsupported_effort "$harness" "$model" "$effort" "pi 0.83.0 rejects --thinking $effort" ;;
      esac
      ;;
    opencode)
      # opencode's interactive `opencode --prompt` launch has no verified effort flag.
      warn_unsupported_effort "$harness" "$model" "$effort" "the interactive opencode --prompt launch has no verified effort flag"
      ;;
  esac
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
    projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

validate_firstmate_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_firstmate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_firstmate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

if [ "$KIND" = secondmate ]; then
  if [ -z "$FIRSTMATE_HOME" ] && [ -f "$STATE/$ID.meta" ]; then
    FIRSTMATE_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$FIRSTMATE_HOME" ]; then
    FIRSTMATE_HOME=$(secondmate_registry_value "$ID" home || true)
  fi
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$FIRSTMATE_HOME" ] || { echo "error: no firstmate home supplied or registered for $ID" >&2; exit 1; }
  PROJ_ABS=$(validate_firstmate_home_for_spawn "$ID" "$FIRSTMATE_HOME")
  WT="$PROJ_ABS"
  # Local-HEAD sync: before launch, fast-forward this secondmate's worktree to the
  # PRIMARY checkout's current default-branch commit, so a freshly spawned or
  # recovery-respawned secondmate always runs the primary's version (AGENTS.md
  # spawn section). Purely local - no fetch: the home is a worktree of this same
  # repo and already holds the commit. ff-only and guarded; a dirty, diverged, or
  # wrong-branch home is left untouched and launches as-is. The agent re-reads
  # AGENTS.md fresh on launch, so no nudge is needed here.
  if sm_primary_head=$(primary_head_commit "$FM_ROOT"); then
    sm_ff_out=$(ff_target "$PROJ_ABS" "secondmate $ID" "$sm_primary_head" yes yes 2>&1 || true)
    case "$sm_ff_out" in
      *': skipped:'*)
        sm_ff_line=$(first_line "$sm_ff_out")
        sm_ff_prefix="secondmate $ID: skipped: "
        sm_ff_reason=${sm_ff_line#"$sm_ff_prefix"}
        echo "warning: secondmate $ID sync skipped before launch: $sm_ff_reason" >&2
        ;;
    esac
  else
    echo "warning: secondmate $ID sync skipped before launch: primary default-branch commit cannot be resolved" >&2
  fi
  # Inheritable-config propagation: push the primary's declared LOCAL config into
  # this secondmate home's config/, so the secondmate's OWN crewmates and backlog
  # backend inherit the primary's settings. config/ is gitignored, so this is a
  # separate copy from the local-HEAD fast-forward above;
  # primary-authoritative and re-pushed on every convergence. config/secondmate-harness
  # is the primary's own knob and is deliberately NOT in the inheritable set
  # (fm-config-inherit-lib.sh). A primary with no inheritable config set is a no-op.
  propagate_inheritable_config "$CONFIG" "$PROJ_ABS/config" \
    || echo "warning: secondmate $ID config inheritance failed for $PROJ_ABS/config" >&2
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
else
  PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
  WT=""
  BRIEF="$DATA/$ID/brief.md"
fi
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }

# PROJ_ABS can still carry a symlinked path component (e.g. macOS's /tmp ->
# /private/tmp) when it came from the ship/scout branch's logical `pwd` above.
# Every backend's own current-path read (tmux's pane_current_path, herdr's
# foreground_cwd, zellij/cmux's active pwd probe against the live shell) can
# report the OS-level, physically-resolved cwd, so comparing it against a
# still-symlinked PROJ_ABS can misfire both ways: false-negative (the poll
# below never notices the pane left the project) or false-positive (the
# isolation guard refuses a spawn that never actually tangled). Canonicalize
# once here so every downstream comparison uses the same physical form
# (docs/herdr-backend.md "Known gaps").
PROJ_ABS_REAL=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P) || PROJ_ABS_REAL="$PROJ_ABS"

canonical_git_common_dir() {  # <path>
  local path=$1 common
  common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  (cd "$common" 2>/dev/null && pwd -P)
}

isolated_worktree_root_real() {  # <path>
  local path=$1 path_real top top_real
  path_real=$(cd "$path" 2>/dev/null && pwd -P) || return 1
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
  top_real=$(cd "$top" 2>/dev/null && pwd -P) || return 1
  [ "$path_real" = "$top_real" ] || return 1
  [ "$path_real" != "$PROJ_ABS_REAL" ] || return 1
  printf '%s\n' "$path_real"
}

PROJ_GIT_COMMON_REAL=$(canonical_git_common_dir "$PROJ_ABS" || true)

# The treehouse worktree poll below can only ever accept a path sharing the
# project's canonical Git common dir, so an unresolvable common dir (project is
# not a git repository) makes the poll unsatisfiable; abort before creating any
# backend window rather than burning the full poll timeout.
if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ] && [ -z "$PROJ_GIT_COMMON_REAL" ]; then
  echo "error: cannot resolve the Git common directory for project '$PROJ_ABS' (not a git repository?); treehouse worktree validation cannot succeed, refusing to launch" >&2
  exit 1
fi

treehouse_project_worktree_root_real() {  # <path>
  local path=$1 root_real common_real
  root_real=$(isolated_worktree_root_real "$path") || return 1
  [ -n "$PROJ_GIT_COMMON_REAL" ] || return 1
  common_real=$(canonical_git_common_dir "$path") || return 1
  [ "$common_real" = "$PROJ_GIT_COMMON_REAL" ] || return 1
  printf '%s\n' "$root_real"
}

worktree_root_real() {  # <path>
  local path=$1 top
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
  (cd "$top" 2>/dev/null && pwd -P)
}

check_worktree_meta_holder() {  # <meta-file> <canonical-worktree>
  local meta=$1 candidate=$2 holder_id holder_wt holder_real backend target state
  holder_id=$(basename "$meta" .meta)
  holder_wt=$(fm_meta_get "$meta" worktree)
  [ -n "$holder_wt" ] || return 0
  holder_real=$(worktree_root_real "$holder_wt" 2>/dev/null || true)
  [ "$holder_real" = "$candidate" ] || return 0
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  if [ -z "$target" ]; then
    echo "error: worktree $candidate is recorded by task $holder_id, but its backend endpoint is missing; refusing to take it over" >&2
    return 1
  fi
  if ! fm_backend_validate "$backend" >/dev/null 2>&1; then
    echo "error: cannot verify the backend endpoint for task $holder_id (backend=$backend target=$target); refusing to take over worktree $candidate" >&2
    return 1
  fi
  state=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null || printf 'unknown')
  # A backend may not have an agent classifier yet, but a definitively gone
  # endpoint is safe to treat as stale; an existing or unreadable endpoint stays
  # fail-closed so an uncertain probe can never duplicate a live agent.
  if [ "$state" = unknown ] \
    && ! fm_backend_target_exists "$backend" "$target" "fm-$holder_id" >/dev/null 2>&1; then
    state=dead
  fi
  case "$state" in
    dead)
      echo "warning: task $holder_id still records worktree $candidate, but its $backend endpoint $target has no agent; treating that metadata as stale" >&2
      ;;
    alive)
      echo "error: worktree $candidate is held by agent task $holder_id (backend=$backend target=$target); refusing to take it over" >&2
      return 1
      ;;
    *)
      echo "error: cannot confirm that task $holder_id has released worktree $candidate (backend=$backend target=$target reported $state); refusing to take it over" >&2
      return 1
      ;;
  esac
}

adopt_recorded_worktree() {
  local recorded_project recorded_project_real validated provider holder_meta
  RECORDED_META="$STATE/$ID.meta"
  RECORDED_WORKTREE=$(fm_meta_get "$RECORDED_META" worktree)
  provider=treehouse
  [ "$BACKEND" = orca ] && provider=orca
  if [ -z "$RECORDED_WORKTREE" ]; then
    echo "warning: task $ID has metadata but no recorded worktree; requesting a fresh $provider worktree; no recorded path is available to inspect for uncommitted work" >&2
    return 0
  fi
  if [ ! -d "$RECORDED_WORKTREE" ]; then
    echo "warning: recorded worktree for task $ID is gone ($RECORDED_WORKTREE); requesting a fresh $provider worktree; uncommitted work may still remain there and a task branch may still be checked out elsewhere; firstmate will not detach it automatically" >&2
    return 0
  fi
  RECORDED_WORKTREE_ROOT=$(worktree_root_real "$RECORDED_WORKTREE" 2>/dev/null || true)
  if [ -z "$RECORDED_WORKTREE_ROOT" ]; then
    echo "error: recorded worktree for task $ID still exists at $RECORDED_WORKTREE but is not a Git worktree; refusing to allocate another worktree" >&2
    return 1
  fi
  if [ "$RECORDED_WORKTREE_ROOT" = "$PROJ_ABS_REAL" ]; then
    echo "error: recorded worktree for task $ID resolves to the primary project checkout $PROJ_ABS_REAL; refusing to launch" >&2
    return 1
  fi
  recorded_project=$(fm_meta_get "$RECORDED_META" project)
  if [ -n "$recorded_project" ] && [ -d "$recorded_project" ]; then
    recorded_project_real=$(cd "$recorded_project" 2>/dev/null && pwd -P || true)
    if [ -n "$recorded_project_real" ] && [ "$recorded_project_real" != "$PROJ_ABS_REAL" ]; then
      echo "error: task $ID metadata belongs to project $recorded_project_real, not requested project $PROJ_ABS_REAL; refusing to reuse its worktree" >&2
      return 1
    fi
  fi
  WT="$RECORDED_WORKTREE_ROOT"
  if [ "$BACKEND" = orca ]; then
    validate_spawn_worktree "recorded task metadata" "$ID"
  else
    validated=$(treehouse_project_worktree_root_real "$WT" || true)
    if [ -z "$validated" ]; then
      echo "error: recorded worktree for task $ID is not an isolated worktree of the requested project ($WT); refusing to allocate another worktree" >&2
      return 1
    fi
    WT=$validated
  fi
  for holder_meta in "$STATE"/*.meta; do
    [ -e "$holder_meta" ] || continue
    check_worktree_meta_holder "$holder_meta" "$WT" || return 1
  done
  REUSE_RECORDED_WORKTREE=1
  echo "reusing recorded worktree for task $ID: $WT" >&2
}

# Session-provider container-ensure + task creation. tmux stays exactly as P1
# left it (same session-name / new-window sequence, see bin/backends/tmux.sh);
# a herdr spawn goes through the version-gated, workspace-per-HOME,
# tab-per-task sequence in bin/backends/herdr.sh instead (D4/D5 as refined by
# docs/herdr-backend.md's "workspace-per-home" pass, AGENTS.md task
# herdr-sm-spaces-k4). Both branches converge on the same $T ("target") string
# that every downstream operation (send/capture/kill) already treats as opaque
# per-backend routing (fm_backend_resolve_selector).
validate_spawn_worktree() {  # <source> <inspect-target>
  local source=$1 inspect_target=$2 wt_real wt_top
  wt_real=$(isolated_worktree_root_real "$WT" || true)
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -z "$wt_real" ]; then
    echo "error: $source did not yield an isolated worktree (resolved '$WT'; worktree root '${wt_top:-none}'; primary '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout. Inspect target $inspect_target" >&2
    exit 1
  fi
}

validate_treehouse_project_worktree() {  # <source> <inspect-target>
  local source=$1 inspect_target=$2 wt_real wt_top wt_common
  wt_real=$(treehouse_project_worktree_root_real "$WT" || true)
  if [ -n "$wt_real" ]; then
    return 0
  fi
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
  wt_common=$(canonical_git_common_dir "$WT" || true)
  echo "error: $source did not yield a worktree for the requested project (resolved '$WT'; worktree root '${wt_top:-none}'; Git common directory '${wt_common:-none}'; expected '$PROJ_GIT_COMMON_REAL'; primary '$PROJ_ABS'); refusing to launch. Inspect target $inspect_target" >&2
  exit 1
}

REUSE_RECORDED_WORKTREE=0
RECORDED_META=
RECORDED_WORKTREE=
RECORDED_WORKTREE_ROOT=
if [ "$KIND" != secondmate ] && [ -f "$STATE/$ID.meta" ]; then
  adopt_recorded_worktree || exit 1
fi

W="fm-$ID"
SPAWN_CWD=$PROJ_ABS
[ "$REUSE_RECORDED_WORKTREE" -eq 1 ] && SPAWN_CWD=$WT
case "$BACKEND" in
  tmux)
    SES=$(fm_backend_tmux_container_ensure)
    T="$SES:$W"
    # #134 robustness (tmux): fm_backend_tmux_create_task captures a stable window
    # id and pins the window name (automatic-rename/allow-rename off) so a captain's
    # non-default tmux config cannot rename the window away from fm-<id> once
    # treehouse cd's into the worktree. WT_TARGET carries that stable id for the
    # rename-critical worktree-detection steps below; the persisted window= handle
    # stays $T (the name form), which is safe now that rename is disabled.
    WID=$(fm_backend_tmux_create_task "$SES" "$W" "$SPAWN_CWD") || exit 1
    WT_TARGET="$WID"
    ;;
  herdr)
    # fm_backend_herdr_workspace_label resolves the target workspace from
    # FM_HOME. For every KIND except secondmate, this process's own FM_HOME is
    # already the right home (the primary spawning its own crewmate/scout, or
    # a secondmate spawning ITS OWN crewmate/scout from its own process's
    # FM_HOME - the latter needs no glue at all). A --secondmate spawn is the
    # one case that does: it is the PRIMARY's own fm-spawn.sh process
    # launching a DIFFERENT home (PROJ_ABS, already validated above as the
    # secondmate's home), so FM_HOME here still names the primary. Shadow it
    # to PROJ_ABS for just these two calls (bash restores it automatically
    # after each prefixed simple-command call) so the secondmate's tab lands
    # in the secondmate's own workspace, not the primary's "firstmate" one.
    HERDR_LABEL_HOME=$FM_HOME
    if [ "$KIND" = secondmate ]; then
      HERDR_LABEL_HOME=$PROJ_ABS
    fi
    HERDR_CONTAINER_RAW=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_container_ensure "$PROJ_ABS") || exit 1
    # fm_backend_herdr_container_ensure echoes "<session>:<workspace_id>\t<seeded_default_tab_id>"
    # (the second field empty when this call ADOPTED a pre-existing workspace
    # rather than creating a fresh one). Split on the guaranteed single tab
    # character; the seeded tab id is threaded through to create_task
    # untouched, which is the only function permitted to prune it (never
    # re-derived from labels - see docs/herdr-backend.md "Default-tab prune").
    CONTAINER=${HERDR_CONTAINER_RAW%%$'\t'*}
    HERDR_SEEDED_DEFAULT_TAB_ID=${HERDR_CONTAINER_RAW#*$'\t'}
    HERDR_SES=${CONTAINER%%:*}
    HERDR_WORKSPACE_ID=${CONTAINER#*:}
    HERDR_TASK_IDS=$(FM_HOME="$HERDR_LABEL_HOME" fm_backend_herdr_create_task "$CONTAINER" "$W" "$SPAWN_CWD" "$HERDR_SEEDED_DEFAULT_TAB_ID") || exit 1
    read -r HERDR_TAB_ID HERDR_PANE_ID <<EOF
$HERDR_TASK_IDS
EOF
    if [ -z "$HERDR_TAB_ID" ] || [ -z "$HERDR_PANE_ID" ]; then
      echo "error: herdr did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$HERDR_SES:$HERDR_PANE_ID"
    ;;
  zellij)
    ZELLIJ_SES=$(fm_backend_zellij_container_ensure) || exit 1
    ZELLIJ_TASK_IDS=$(fm_backend_zellij_create_task "$ZELLIJ_SES" "$W" "$SPAWN_CWD") || exit 1
    read -r ZELLIJ_TAB_ID ZELLIJ_PANE_ID <<EOF
$ZELLIJ_TASK_IDS
EOF
    if [ -z "$ZELLIJ_TAB_ID" ] || [ -z "$ZELLIJ_PANE_ID" ]; then
      echo "error: zellij did not return a tab/pane id for $W" >&2
      exit 1
    fi
    T="$ZELLIJ_SES:$ZELLIJ_PANE_ID"
    ;;
  cmux)
    fm_backend_cmux_container_ensure || exit 1
    CMUX_TASK_IDS=$(fm_backend_cmux_create_task "$W" "$SPAWN_CWD") || exit 1
    read -r CMUX_WORKSPACE_ID CMUX_SURFACE_ID <<EOF
$CMUX_TASK_IDS
EOF
    if [ -z "$CMUX_WORKSPACE_ID" ] || [ -z "$CMUX_SURFACE_ID" ]; then
      echo "error: cmux did not return a workspace/surface id for $W" >&2
      exit 1
    fi
    T="$CMUX_WORKSPACE_ID:$CMUX_SURFACE_ID"
    ;;
  orca)
    if [ "$REUSE_RECORDED_WORKTREE" -eq 1 ]; then
      ORCA_WORKTREE_ID=$(fm_meta_get "$RECORDED_META" orca_worktree_id)
      [ -n "$ORCA_WORKTREE_ID" ] || {
        echo "error: task $ID has a recorded Orca worktree path but no Orca worktree id; refusing to allocate another worktree" >&2
        exit 1
      }
      ORCA_ABORT_CLEANUP=0
      validate_spawn_worktree "recorded task metadata" "$W"
    else
      set +e
      ORCA_WT_RAW=$(fm_backend_orca_worktree_create "$PROJ_ABS" "$W")
      ORCA_WT_STATUS=$?
      set -e
      if [ "$ORCA_WT_STATUS" -ne 0 ]; then
        if [ "$ORCA_WT_STATUS" -eq 2 ] && [ -n "$ORCA_WT_RAW" ]; then
          if parse_orca_worktree_result "$ORCA_WT_RAW" && [ -n "$ORCA_WORKTREE_ID" ]; then
            ORCA_ABORT_CLEANUP=1
          fi
        fi
        exit 1
      fi
      parse_orca_worktree_result "$ORCA_WT_RAW" || true
      ORCA_ABORT_CLEANUP=1
    fi
    if [ -z "$ORCA_WORKTREE_ID" ] || [ -z "$WT" ]; then
      echo "error: orca did not return a worktree id/path for $W" >&2
      exit 1
    fi
    [ "$REUSE_RECORDED_WORKTREE" -eq 1 ] || validate_spawn_worktree "orca worktree create" "$W"
    if [ -z "$ORCA_TERMINAL" ]; then
      ORCA_TERMINAL=$(fm_backend_orca_terminal_create "$ORCA_WORKTREE_ID" "$W") || exit 1
    fi
    T="$ORCA_TERMINAL"
    ;;
esac
# #134 robustness: only tmux needs a worktree-detection target distinct from $T -
# its rename-safe stable window id, set as WT_TARGET=$WID in the tmux branch above.
# Every other backend addresses its pane/surface by the id already in $T, so default
# WT_TARGET to $T for them (and for any future backend) - the shared treehouse-get +
# worktree-detection steps below must never reference an unbound WT_TARGET under set -u.
: "${WT_TARGET:=$T}"
spawn_send_text_line() {  # <target> <text>
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_text_line "$1" "$2" ;;
    herdr) fm_backend_herdr_send_text_line "$1" "$2" ;;
    zellij) fm_backend_zellij_send_text_line "$1" "$2" "$W" ;;
    orca) fm_backend_orca_send_text_line "$1" "$2" ;;
    cmux) fm_backend_cmux_send_text_line "$1" "$2" "$W" ;;
  esac
}
spawn_current_path() {  # <target>
  case "$BACKEND" in
    tmux) fm_backend_tmux_current_path "$1" ;;
    herdr) fm_backend_herdr_current_path "$1" ;;
    zellij) fm_backend_zellij_current_path "$1" "$W" ;;
    cmux) fm_backend_cmux_current_path "$1" "$W" ;;
  esac
}
if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ] && [ "$REUSE_RECORDED_WORKTREE" -eq 0 ]; then
  spawn_send_text_line "$WT_TARGET" 'treehouse get'

  # Wait for the treehouse subshell: the pane's cwd moves from the project to a
  # linked worktree of that same project. Shell startup can transiently visit
  # unrelated directories, including other Git repositories, so accept only a
  # distinct canonical worktree root with the project's canonical common dir.
  # Target the stable window id, not the name: if the name is ever lost (e.g. an
  # automatic-rename slips through), display-message -t <bad-name> falls back to the
  # active client's window, which would misread firstmate's OWN pane path as the
  # worktree and tangle a hook into the primary checkout. The window id never lies.
  LAST_POLLED_PATH=""
  for _ in $(seq 1 60); do
    p=$(spawn_current_path "$WT_TARGET" || true)
    if [ -n "$p" ]; then
      LAST_POLLED_PATH="$p"
      if treehouse_project_worktree_root_real "$p" >/dev/null; then
        WT="$p"
        break
      fi
    fi
    sleep 1
  done
  if [ -z "$WT" ]; then
    LAST_POLLED_COMMON=""
    if [ -n "$LAST_POLLED_PATH" ]; then
      LAST_POLLED_COMMON=$(canonical_git_common_dir "$LAST_POLLED_PATH" || true)
    fi
    echo "error: treehouse get did not enter a worktree of the requested project within 60s (last observed path '${LAST_POLLED_PATH:-none}'; its Git common directory '${LAST_POLLED_COMMON:-none}'; expected '$PROJ_GIT_COMMON_REAL'; primary '$PROJ_ABS'); inspect window $T" >&2
    exit 1
  fi

  # Re-run the full project-identity check after discovery so the launch boundary
  # remains fail-closed even if the polling implementation is later refactored.
  validate_treehouse_project_worktree "treehouse get" "$T"
fi

RESOURCE_HOME=$FM_HOME
RESOURCE_ROOT=$FM_ROOT
if [ "$KIND" = secondmate ]; then
  RESOURCE_HOME=$PROJ_ABS
  RESOURCE_ROOT=$PROJ_ABS
fi
# Per-task temp root: /tmp/fm-<id>/ with Go's build temp nested at gotmp/. The
# ownership preparation below creates GOTMPDIR and its marker before the task uses it.
# Nested (not a bare /tmp/fm-<id>/gotmp) so other per-task temp can live alongside
# later, and teardown cleans one deterministic path. GOTMPDIR (not TMPDIR) is the
# targeted knob: TMPDIR is too broad (affects every program's temp, not just Go's).
TASK_TMP="/tmp/fm-$ID"
EXPECTED_RESOURCE_OWNER=$(fm_resource_owner_for "$RESOURCE_HOME" "$RESOURCE_ROOT" "$ID")
if [ -e "$TASK_TMP" ] || [ -L "$TASK_TMP" ]; then
  EXISTING_RESOURCE_OWNER=$(fm_resource_marker_get "$TASK_TMP/$FM_RESOURCE_OWNER_MARKER" owner 2>/dev/null || true)
  if [ -L "$TASK_TMP" ] || [ "$EXISTING_RESOURCE_OWNER" != "$EXPECTED_RESOURCE_OWNER" ]; then
    RESOURCE_HOME_TAG=$(fm_resource_home_tag_for "$RESOURCE_HOME" "$RESOURCE_ROOT")
    TASK_TMP="/tmp/fm-$ID-$RESOURCE_HOME_TAG"
  fi
fi

# Resource ownership is established before the agent launch, so a killed agent
# cannot take the ownership record with it. A task that explicitly connects to an
# externally owned browser keeps that browser unowned and is never stopped by teardown.
BROWSER_RESOURCE_OWNED=1
[ -z "${CHROME_DEVTOOLS_AXI_BROWSER_URL:-}" ] || BROWSER_RESOURCE_OWNED=0
if [ "${CHROME_DEVTOOLS_AXI_AUTO_CONNECT:-0}" = 1 ] || [ "${CHROME_DEVTOOLS_AXI_AUTO_CONNECT:-0}" = true ]; then
  BROWSER_RESOURCE_OWNED=0
fi
[ -z "${CHROME_DEVTOOLS_AXI_USER_DATA_DIR:-}" ] || BROWSER_RESOURCE_OWNED=0
TASK_RESOURCE_MANIFEST=$(fm_resource_prepare_task "$ID" "$RESOURCE_HOME" "$RESOURCE_ROOT" "$STATE" "$TASK_TMP" "$BACKEND" "$T" "$BROWSER_RESOURCE_OWNED")
TASK_RESOURCE_OWNER=$(fm_resource_manifest_get "$TASK_RESOURCE_MANIFEST" owner)
RESOURCE_ENV=$(fm_resource_task_env_line "$TASK_RESOURCE_MANIFEST")

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
mkdir -p "$STATE"
STATE_REAL=$(cd "$STATE" && pwd -P)
TURNEND="$STATE_REAL/$ID.turn-ended"
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
if [ "$KIND" != secondmate ]; then
  case "$HARNESS" in
    claude*)
      mkdir -p "$WT/.claude"
      cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
      exclude_path '.claude/settings.local.json'
      ;;
    opencode*)
      mkdir -p "$WT/.opencode/plugins"
      cat > "$WT/.opencode/plugins/fm-turn-end.js" <<EOF
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $TURNEND\`
  },
})
EOF
      exclude_path '.opencode/plugins/fm-turn-end.js'
      ;;
    pi*)
      # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
      # loaded from inside the project (verified live), but an explicit -e path
      # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
      cat > "$STATE/$ID.pi-ext.ts" <<EOF
// Firstmate turn-end signal; written by fm-spawn.
// Use "turn_end" (fires after each turn the agent finishes), not "agent_end"
// (fires once, only when the whole run exits): the watcher needs a signal at
// every turn boundary so an idle crewmate is surfaced, not just at shutdown.
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["$TURNEND"]));
}
EOF
      ;;
    codex*)
      # codex: turn-end rides the launch command via -c notify=[...] and __TURNEND__.
      ;;
    grok*)
      # grok fires a Stop hook at every turn boundary (verified, grok 0.2.73), the
      # clean equivalent of codex's notify= and pi's turn_end. But grok only loads
      # PROJECT hooks (<worktree>/.grok/hooks/, <worktree>/.claude/settings.local.json)
      # after the folder is granted hook-trust, which is not automatic and which
      # firstmate cannot establish at launch without editing grok's own managed
      # trust store (a high-blast-radius write). GLOBAL hooks in ~/.grok/hooks/ are
      # always trusted and load on first launch with no gate. So the turn-end hook
      # lives OUTSIDE the worktree as a single firstmate-owned global hook that is a
      # guarded no-op for every non-firstmate grok session: it fires only when the
      # current workspace holds a .fm-grok-turnend token pointer that matches the
      # firstmate-owned hook registry. firstmate then drops that per-task pointer
      # (gitignored, like the other harnesses' worktree hook files).
      # Result: the hook is outside the worktree, needs no trust grant, and never
      # touches grok's managed config - only firstmate-owned files.
      GROK_HOOKS_DIR="${GROK_HOME:-$HOME/.grok}/hooks"
      GROK_AUTH_DIR="$GROK_HOOKS_DIR/fm-turn-end.d"
      mkdir -p "$GROK_AUTH_DIR"
      old_umask=$(umask)
      umask 077
      auth_file=$(mktemp "$GROK_AUTH_DIR/fm.XXXXXXXXXXXX")
      umask "$old_umask"
      printf '%s\n' "$TURNEND" > "$auth_file"
      printf '%s\n' "${auth_file##*/}" > "$STATE/$ID.grok-turnend-token"
      sq_grok_auth_dir=$(shell_quote "$GROK_AUTH_DIR")
      cat > "$GROK_HOOKS_DIR/fm-turn-end.sh" <<EOF
#!/usr/bin/env bash
set -u
auth_dir=$sq_grok_auth_dir
workspace=\${GROK_WORKSPACE_ROOT:-}
[ -n "\$workspace" ] || exit 0
p="\$workspace/.fm-grok-turnend"
[ -f "\$p" ] || exit 0
first=
IFS= read -r -n 256 first < "\$p" 2>/dev/null || [ -n "\$first" ] || exit 0
case "\$first" in token=*) token=\${first#token=} ;; *) exit 0 ;; esac
case "\$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "\$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
t=\$(cat "\$auth_dir/\$token" 2>/dev/null) || exit 0
case "\$t" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch "\$t" 2>/dev/null || true
exit 0
EOF
      chmod +x "$GROK_HOOKS_DIR/fm-turn-end.sh"
      hook_command=$(json_escape "bash $(shell_quote "$GROK_HOOKS_DIR/fm-turn-end.sh")")
      printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' "$hook_command" > "$GROK_HOOKS_DIR/fm-turn-end.json"
      printf 'token=%s\n' "${auth_file##*/}" > "$WT/.fm-grok-turnend"
      exclude_path '.fm-grok-turnend'
      ;;
  esac
fi

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; AGENTS.md project management and task lifecycle).
# Recorded in meta so fm-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
SECONDMATE_PROJECTS=
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
  SECONDMATE_PROJECTS=$(secondmate_registry_value "$ID" projects || true)
else
  PROJ_NAME=$(basename "$PROJ_ABS")
  read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME")
EOF
fi

META_WINDOW=$T
[ "$BACKEND" = orca ] && META_WINDOW=$W
{
  echo "window=$META_WINDOW"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "tasktmp=$TASK_TMP"
  echo "resource_manifest=$TASK_RESOURCE_MANIFEST"
  echo "resource_owner=$TASK_RESOURCE_OWNER"
  echo "resource_home=$RESOURCE_HOME"
  echo "resource_root=$RESOURCE_ROOT"
  echo "model=${MODEL:-default}"
  echo "effort=${EFFORT:-default}"
  # backend= is written only for a non-default (non-tmux) backend, so the
  # default path's meta stays byte-identical (absent backend= means tmux;
  # data/fm-backend-design-d7's P1 compatibility contract).
  [ "$BACKEND" = tmux ] || echo "backend=$BACKEND"
  if [ "$BACKEND" = herdr ]; then
    echo "herdr_session=$HERDR_SES"
    echo "herdr_workspace_id=$HERDR_WORKSPACE_ID"
    echo "herdr_tab_id=$HERDR_TAB_ID"
    echo "herdr_pane_id=$HERDR_PANE_ID"
  fi
  if [ "$BACKEND" = zellij ]; then
    echo "zellij_session=$ZELLIJ_SES"
    echo "zellij_tab_id=$ZELLIJ_TAB_ID"
    echo "zellij_pane_id=$ZELLIJ_PANE_ID"
  fi
  if [ "$BACKEND" = orca ]; then
    echo "orca_worktree_id=$ORCA_WORKTREE_ID"
    echo "terminal=$ORCA_TERMINAL"
  fi
  if [ "$BACKEND" = cmux ]; then
    echo "cmux_workspace_id=$CMUX_WORKSPACE_ID"
    echo "cmux_surface_id=$CMUX_SURFACE_ID"
  fi
  if [ "$KIND" = secondmate ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  fi
} > "$STATE/$ID.meta"
[ "$BACKEND" = orca ] && ORCA_ABORT_CLEANUP=0

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
sq_piturnend=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-turnend-guard.ts")
sq_piwatch=$(shell_quote "$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts")
# A raw launch already warned that both axes are ignored; skip the per-harness
# resolution so a raw command whose first word matches a known adapter cannot emit
# a second, adapter-specific warning about a launch firstmate does not build.
if [ "$RAW_LAUNCH" -eq 1 ]; then
  MODELFLAG=
  EFFORTFLAG=
else
  MODELFLAG=$(model_flag_for_harness "$HARNESS" "$MODEL")
  EFFORTFLAG=$(effort_flag_for_harness "$HARNESS" "$MODEL" "$EFFORT")
fi
LAUNCH=${LAUNCH//__MODELFLAG__/$MODELFLAG}
LAUNCH=${LAUNCH//__EFFORTFLAG__/$EFFORTFLAG}
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
LAUNCH=${LAUNCH//__PITURNEND__/$sq_piturnend}
LAUNCH=${LAUNCH//__PIWATCH__/$sq_piwatch}
if [ "$KIND" = secondmate ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$sq_home $LAUNCH"
fi
# Export GOTMPDIR into the crewmate's pane shell so the agent and every child
# process (go build, go test, ...) inherit it, then launch the agent. Everything
# goes into one launch file in the task temp root and the pane receives a single
# short `. <file>` line: typing several long lines while the freshly entered
# worktree shell is still initialising let zsh's line editor interleave and
# scramble the typeahead (2026-09-26/27, herdr and tmux alike), leaving the pane
# in a broken continuation prompt instead of starting the agent.
LAUNCH_FILE="$TASK_TMP/launch.sh"
{
  printf 'export GOTMPDIR=%s\n' "$(shell_quote "$TASK_TMP/gotmp")"
  while IFS= read -r resource_env_line; do
    [ -n "$resource_env_line" ] || continue
    printf '%s\n' "$resource_env_line"
  done <<EOF
$RESOURCE_ENV
EOF
  printf '%s\n' "$LAUNCH"
} > "$LAUNCH_FILE"
sleep 0.3
spawn_send_text_line "$T" ". $(shell_quote "$LAUNCH_FILE")"

echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO window=$META_WINDOW worktree=$WT"
