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

cleanup_spawn_tmp() {
  [ "$TASK_TMP_OWNED" = 1 ] && [ -e "$TASK_TMP" ] && find "$TASK_TMP" -depth -delete
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
  fm_fake_exit0 "$fakebin" treehouse
  fm_fake_exit0 "$fakebin" codex

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

test_long_prelude_is_submitted_once_before_launch
echo "all fm-spawn prelude tests passed"
