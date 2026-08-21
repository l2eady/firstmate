#!/usr/bin/env bash
# Regression coverage for spawn's long shell prelude. The fixture models a
# terminal that keeps a long submitted line pending until the caller observes
# the pane after Enter; blind follow-up sends then duplicate the pending text.
# The real spawn path is exercised with an isolated fake tmux and worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-prelude)
TASK_ID="spawn-prelude-regression-$(basename "$TMP_ROOT")-$$-${RANDOM:-0}"
TASK_TMP="/tmp/fm-$TASK_ID"
TASK_TMP_OWNED=1
[ ! -e "$TASK_TMP" ] && [ ! -L "$TASK_TMP" ] || {
  printf 'not ok - refusing pre-existing spawn fixture path %s\n' "$TASK_TMP" >&2
  exit 1
}
SERIAL_TASK_ID="spawn-serialization-regression-$(basename "$TMP_ROOT")-$$-${RANDOM:-0}"
SERIAL_TASK_TMP="/tmp/fm-$SERIAL_TASK_ID"
[ ! -e "$SERIAL_TASK_TMP" ] && [ ! -L "$SERIAL_TASK_TMP" ] || {
  printf 'not ok - refusing pre-existing spawn fixture path %s\n' "$SERIAL_TASK_TMP" >&2
  exit 1
}

cleanup_spawn_tmp() {
  [ "$TASK_TMP_OWNED" = 1 ] && [ -e "$TASK_TMP" ] && find "$TASK_TMP" -depth -delete
  [ -e "$SERIAL_TASK_TMP" ] && find "$SERIAL_TASK_TMP" -depth -delete
  fm_test_cleanup
}
trap cleanup_spawn_tmp EXIT

test_long_prelude_is_submitted_once_before_launch() {
  local home="$TMP_ROOT/home" project="$TMP_ROOT/project" worktree="$TMP_ROOT/worktree"
  local fakebin="$TMP_ROOT/fakebin" log="$TMP_ROOT/tmux.log" pending="$TMP_ROOT/pending"
  local out status duplicate compose_sends blind_compose prelude_line launch_line owner home_abs root_abs home_tag
  fm_git_init_commit "$project"
  git -C "$project" worktree add -q --detach "$worktree"
  mkdir -p "$home/data/$TASK_ID" "$home/state" "$home/config" "$home/projects" "$fakebin"
  printf 'isolated spawn prelude regression\n' > "$home/data/$TASK_ID/brief.md"
  home_abs=$(cd "$home" && pwd -P)
  root_abs=$(cd "$ROOT" && pwd -P)
  owner=$(FM_HOME="$home" FM_ROOT="$ROOT" bash -c '. "$1/bin/fm-resource-lib.sh"; fm_resource_owner_for "$2" "$3" "$4"' _ "$ROOT" "$home_abs" "$root_abs" "$TASK_ID")
  home_tag=$(FM_HOME="$home" FM_ROOT="$ROOT" bash -c '. "$1/bin/fm-resource-lib.sh"; fm_resource_home_tag_for "$2" "$3"' _ "$ROOT" "$home_abs" "$root_abs")
  mkdir -p "$TASK_TMP/gotmp"
  {
    printf 'version=1\nowner=%s\ntask=%s\nhome=%s\nhome_tag=%s\nroot=%s\nresource=task\n' \
      "$owner" "$TASK_ID" "$home_abs" "$home_tag" "$root_abs"
  } > "$TASK_TMP/.fm-resource-owner"
  printf 'stale-prelude\n' > "$TASK_TMP/.fm-spawn-prelude"
  printf 'stale-launch\n' > "$TASK_TMP/.fm-spawn-launch"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_PRELUDE_LOG:?}
pending=${FM_PRELUDE_PENDING:?}
printf 'tmux %s\n' "$*" >> "$log"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_PRELUDE_WORKTREE:?}"; exit 0 ;;
  *"#{pane_current_command}"*) printf 'bash\n'; exit 0 ;;
  *"#{pane_id}"*) printf '%%1\n'; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '@prelude-wid\n'; exit 0 ;;
  send-keys)
    text_send=0
    case "$*" in
      *" -l "*) text_send=1 ;;
      *)
        if [ "$#" -eq 4 ] && [ "$1" = send-keys ] && [ "$2" = -t ] && [ "$4" = Enter ]; then
          text_send=0
        else
          text_send=1
        fi
        ;;
    esac
    if [ "$text_send" = 1 ] && [ "$(cat "$pending" 2>/dev/null || true)" = pending ]; then
      printf 'duplicate: follow-up send arrived before the previous prelude was observed\n' >> "$log"
    fi
    case "$*" in
      *COMPOSE_PROJECT_NAME*) printf 'pending\n' > "$pending" ;;
    esac
    text=${5:-}
    case "$text" in
      *fm-spawn-prelude*|*fm-spawn-launch*)
        (cd "${FM_PRELUDE_WORKTREE:?}" && bash -c "$text") >/dev/null 2>&1 || true
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    printf 'observed\n' > "$pending"
    printf '$ \n'
    exit 0
    ;;
  list-windows|has-session|new-session|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse codex

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    FM_SPAWN_SUBMIT_RETRIES=2 FM_SPAWN_SUBMIT_SLEEP=0 FM_SPAWN_SUBMIT_SETTLE=0 \
    FM_PRELUDE_LOG="$log" FM_PRELUDE_PENDING="$pending" FM_PRELUDE_WORKTREE="$worktree" \
    TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$TASK_ID" "$project" codex 2>&1)
  status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    [ ! -f "$log" ] || { printf '%s\n' '--- fake tmux log ---' >&2; cat "$log" >&2; }
    [ ! -f "$TASK_TMP/.fm-spawn-prelude.sh" ] || { printf '%s\n' '--- prelude script ---' >&2; cat "$TASK_TMP/.fm-spawn-prelude.sh" >&2; }
    fail "verified spawn prelude fixture failed"
  fi

  duplicate=$(grep -c '^duplicate:' "$log" || true)
  [ "$duplicate" -eq 0 ] || fail "spawn duplicated a pending prelude send ($duplicate marker(s))"
  [ -f "$TASK_TMP/.fm-spawn-prelude" ] || fail "spawn did not observe the shell-side prelude acknowledgement"
  [ -f "$TASK_TMP/.fm-spawn-launch" ] || fail "spawn did not observe the shell-side launch acknowledgement"
  [ "$(cat "$TASK_TMP/.fm-spawn-prelude")" != stale-prelude ] || fail "spawn accepted a stale prelude acknowledgement"
  [ "$(cat "$TASK_TMP/.fm-spawn-launch")" != stale-launch ] || fail "spawn accepted a stale launch acknowledgement"
  case "$(cat "$TASK_TMP/.fm-spawn-prelude")" in prelude:*) ;; *) fail "prelude acknowledgement did not carry the current attempt nonce" ;; esac
  case "$(cat "$TASK_TMP/.fm-spawn-launch")" in launch:*) ;; *) fail "launch acknowledgement did not carry the current attempt nonce" ;; esac
  [ -f "$TASK_TMP/.fm-spawn-prelude.sh" ] || fail "spawn did not write the task-local prelude script"
  compose_sends=$(grep -c 'COMPOSE_PROJECT_NAME=' "$TASK_TMP/.fm-spawn-prelude.sh" || true)
  [ "$compose_sends" -eq 1 ] || fail "COMPOSE_PROJECT_NAME was not written exactly once to the task-local prelude (count=$compose_sends)"
  blind_compose=$(grep -c -- 'send-keys -t @prelude-wid .*COMPOSE_PROJECT_NAME' "$log" || true)
  [ "$blind_compose" -eq 0 ] || fail "COMPOSE_PROJECT_NAME was sent through the terminal input path"
  prelude_line=$(grep -n -F '.fm-spawn-prelude' "$log" | head -1 | cut -d: -f1)
  launch_line=$(grep -n -F '.fm-spawn-launch' "$log" | head -1 | cut -d: -f1)
  [ -n "$prelude_line" ] && [ -n "$launch_line" ] && [ "$prelude_line" -lt "$launch_line" ] \
    || fail "launch was submitted before the prelude acknowledgement"
  pass "spawn submits the long resource prelude once, observes it, and launches without duplication"
}

test_environment_and_launch_are_serialized_once() {
  local task_id="$SERIAL_TASK_ID" task_tmp="$SERIAL_TASK_TMP"
  local home="$TMP_ROOT/serialization-home with 'quote'" project="$TMP_ROOT/serialization-project" worktree="$TMP_ROOT/serialization-worktree"
  local fakebin="$TMP_ROOT/serialization-fakebin" log="$TMP_ROOT/serialization-tmux.log" pending="$TMP_ROOT/serialization-pending"
  local codex_log="$TMP_ROOT/serialization-codex.log" codex_args="$TMP_ROOT/serialization-codex.args"
  local codex_path="$TMP_ROOT/serialization-codex.path" codex_home="$TMP_ROOT/serialization-codex.home"
  local codex_owner="$TMP_ROOT/serialization-codex.owner" prelude_script launch_script
  local out status source_count launch_count path_export_count owner home_abs root_abs home_tag
  local original_path expected_path
  fm_git_init_commit "$project"
  git -C "$project" worktree add -q --detach "$worktree"
  mkdir -p "$home/data/$task_id" "$home/state" "$home/config" "$home/projects" "$fakebin"
  printf 'isolated spawn serialization regression\n' > "$home/data/$task_id/brief.md"
  home_abs=$(cd "$home" && pwd -P)
  root_abs=$(cd "$ROOT" && pwd -P)
  owner=$(FM_HOME="$home" FM_ROOT="$ROOT" bash -c '. "$1/bin/fm-resource-lib.sh"; fm_resource_owner_for "$2" "$3" "$4"' _ "$ROOT" "$home_abs" "$root_abs" "$task_id")
  home_tag=$(FM_HOME="$home" FM_ROOT="$ROOT" bash -c '. "$1/bin/fm-resource-lib.sh"; fm_resource_home_tag_for "$2" "$3"' _ "$ROOT" "$home_abs" "$root_abs")
  mkdir -p "$task_tmp/gotmp"
  printf 'version=1\nowner=%s\ntask=%s\nhome=%s\nhome_tag=%s\nroot=%s\nresource=task\n' \
    "$owner" "$task_id" "$home_abs" "$home_tag" "$root_abs" > "$task_tmp/.fm-resource-owner"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_PRELUDE_LOG:?}
pending=${FM_PRELUDE_PENDING:?}
shell_state=${FM_PRELUDE_STATE:?}
worktree=${FM_PRELUDE_WORKTREE:?}

run_pending() {
  local command
  [ -f "$pending" ] || return 0
  command=$(cat "$pending")
  : > "$pending"
  printf 'execute %s\n' "$command" >> "$log"
  (
    cd "$worktree" || exit 1
    [ ! -f "$shell_state" ] || . "$shell_state"
    eval "$command"
    export -p > "$shell_state"
  ) >> "$log" 2>&1 || true
}

printf 'tmux %s\n' "$*" >> "$log"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$worktree"; exit 0 ;;
  *"#{pane_current_command}"*) printf 'bash\n'; exit 0 ;;
  *"#{pane_id}"*) printf '%%1\n'; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '@serialization-wid\n'; exit 0 ;;
  send-keys)
    case "${4:-}" in
      -l)
        printf '%s' "${5:-}" > "$pending"
        printf 'literal %s\n' "${5:-}" >> "$log"
        ;;
      Enter)
        run_pending
        ;;
      treehouse)
        [ "${5:-}" = get ] && [ "${6:-}" = Enter ] || exit 1
        ;;
      *)
        [ "${5:-}" = Enter ] || exit 1
        printf '%s' "${4:-}" > "$pending"
        run_pending
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    printf '$ \n'
    exit 0
    ;;
  list-windows|has-session|new-session|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse"

  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = debug ] && [ "${2:-}" = models ]; then
  printf '%s\n' '{"models":[{"slug":"gpt-5.6-luna","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}]}]}'
  exit 0
fi
printf 'launch\n' >> "${FM_PRELUDE_CODEX_LOG:?}"
printf '%s\n' "$@" > "${FM_PRELUDE_CODEX_ARGS:?}"
printf '%s\n' "$PATH" > "${FM_PRELUDE_CODEX_PATH:?}"
printf '%s\n' "${FM_TASK_RESOURCE_HOME:?}" > "${FM_PRELUDE_CODEX_HOME:?}"
printf '%s\n' "${FM_TASK_RESOURCE_OWNER:?}" > "${FM_PRELUDE_CODEX_OWNER:?}"
exit 0
SH
  chmod +x "$fakebin/codex"

  original_path=$PATH
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    FM_SPAWN_SUBMIT_RETRIES=2 FM_SPAWN_SUBMIT_SLEEP=0 FM_SPAWN_SUBMIT_SETTLE=0 \
    FM_PRELUDE_LOG="$log" FM_PRELUDE_PENDING="$pending" FM_PRELUDE_STATE="$TMP_ROOT/shell-state" FM_PRELUDE_WORKTREE="$worktree" \
    FM_PRELUDE_CODEX_LOG="$codex_log" FM_PRELUDE_CODEX_ARGS="$codex_args" \
    FM_PRELUDE_CODEX_PATH="$codex_path" FM_PRELUDE_CODEX_HOME="$codex_home" \
    FM_PRELUDE_CODEX_OWNER="$codex_owner" \
    TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$task_id" "$project" --harness codex --model gpt-5.6-luna --effort max 2>&1)
  status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    [ ! -f "$log" ] || { printf '%s\n' '--- fake tmux log ---' >&2; cat "$log" >&2; }
    [ ! -f "$task_tmp/.fm-spawn-prelude.sh" ] || { printf '%s\n' '--- prelude script ---' >&2; cat "$task_tmp/.fm-spawn-prelude.sh" >&2; }
    [ ! -f "$task_tmp/.fm-spawn-launch.sh" ] || { printf '%s\n' '--- launch script ---' >&2; cat "$task_tmp/.fm-spawn-launch.sh" >&2; }
    fail "verified spawn serialization fixture failed"
  fi

  prelude_script="$task_tmp/.fm-spawn-prelude.sh"
  launch_script="$task_tmp/.fm-spawn-launch.sh"
  [ -f "$prelude_script" ] || fail "spawn did not write the task-local prelude script"
  [ -f "$launch_script" ] || fail "spawn did not write the task-local launch script"
  assert_grep 'export PATH=' "$prelude_script" "prelude did not serialize the task PATH export"
  # shellcheck disable=SC2016 # The assertion matches the literal expansion in the generated script.
  assert_grep ':"$PATH"' "$prelude_script" "prelude did not quote the inherited PATH expansion"
  case "$(cat "$task_tmp/.fm-spawn-launch")" in
    launch:*) ;;
    *) fail "launch acknowledgement did not carry the current attempt nonce" ;;
  esac
  source_count=$(grep -c 'literal .*\.fm-spawn-launch\.sh' "$log" || true)
  [ "$source_count" -eq 1 ] || fail "spawn submitted the launch source command $source_count times"
  launch_count=$(grep -c '^launch$' "$codex_log" || true)
  [ "$launch_count" -eq 1 ] || fail "Codex launch count was $launch_count, expected exactly one"
  path_export_count=$(grep -c '^export PATH=' "$prelude_script" || true)
  [ "$path_export_count" -eq 1 ] || fail "prelude contains $path_export_count PATH exports, expected one"
  if grep -Eq 'export PATH=.*export PATH=' "$prelude_script"; then
    fail "prelude contains recursive export PATH construction"
  fi
  assert_grep '--model' "$codex_args" "Codex launch lost the model flag"
  assert_grep 'gpt-5.6-luna' "$codex_args" "Codex launch lost the requested model"
  assert_grep 'model_reasoning_effort="max"' "$codex_args" "Codex launch lost the max effort flag"
  expected_path="$task_tmp/bin:$fakebin:$original_path"
  [ "$(cat "$codex_path")" = "$expected_path" ] \
    || fail "Codex PATH changed more than once: expected '$expected_path', got '$(cat "$codex_path")'"
  [ "$(cat "$codex_home")" = "$home_abs" ] || fail "task resource home lost its spaces or quote"
  [ "$(cat "$codex_owner")" = "$owner" ] || fail "task resource owner was not preserved"
  pass "spawn serializes one environment export and one Codex launch through the disposable shell pane"
}

test_long_prelude_is_submitted_once_before_launch
test_environment_and_launch_are_serialized_once
printf '%s\n' 'all fm-spawn prelude and serialization tests passed'
