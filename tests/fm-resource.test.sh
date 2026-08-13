#!/usr/bin/env bash
# Behavior tests for task resource ownership, cleanup, and orphan safety.
# These tests use exact owner labels and fake Docker, Chrome, and tmux endpoints.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-resource-lib.sh
. "$ROOT/bin/fm-resource-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-resource)
fm_git_identity fmtest fmtest@example.invalid

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

make_fakebin() {
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/docker" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_DOCKER_STATE:?}
case "${1:-}" in
  run|create)
    printf '%s\n' "$*" >> "$state/log"
    touch "$state/has-container" "$state/has-resource"
    ;;
  container|service|compose)
    printf '%s\n' "$*" >> "$state/log"
    case "${2:-}" in
      run|create|up) touch "$state/has-container" "$state/has-resource" ;;
    esac
    ;;
  volume)
    case "${2:-}" in
      ls)
        [ -e "$state/has-volume" ] && printf 'vol1\n'
        ;;
      create)
        touch "$state/has-volume" "$state/has-resource"
        printf '%s\n' "$*" >> "$state/log"
        ;;
      rm)
        rm -f "$state/has-volume" "$state/has-resource"
        touch "$state/removed"
        printf '%s\n' "$*" >> "$state/log"
        ;;
    esac
    ;;
  network)
    case "${2:-}" in
      ls)
        [ -e "$state/has-network" ] && printf 'net1\n'
        ;;
      create)
        touch "$state/has-network" "$state/has-resource"
        printf '%s\n' "$*" >> "$state/log"
        ;;
      rm)
        rm -f "$state/has-network" "$state/has-resource"
        touch "$state/removed"
        printf '%s\n' "$*" >> "$state/log"
        ;;
    esac
    ;;
  ps)
    [ -e "$state/has-container" ] || exit 0
    case "$*" in
      *'com.firstmate.owner='*|*'com.docker.compose.project='*) printf 'cid1\n' ;;
    esac
    ;;
  inspect)
    if [ "${2:-}" = --format ]; then
      case "${4:-}" in
        cid1) [ -e "$state/has-container" ] || exit 1 ;;
        vol1) [ -e "$state/has-volume" ] || exit 1 ;;
        net1) [ -e "$state/has-network" ] || exit 1 ;;
        *) exit 1 ;;
      esac
      printf '%s\tresource-task\tresource-home\ttmux\tfleet:fm-resource-task\tfm-firstmate-resource-task\n' "${FM_FAKE_DOCKER_OWNER:-firstmate:owner:task}"
    else
      case "${2:-}" in
        cid1) [ -e "$state/has-container" ] || exit 1 ;;
        vol1) [ -e "$state/has-volume" ] || exit 1 ;;
        net1) [ -e "$state/has-network" ] || exit 1 ;;
        *) exit 1 ;;
      esac
    fi
    ;;
  rm)
    touch "$state/removed"
    rm -f "$state/has-container" "$state/has-resource"
    printf '%s\n' "$*" >> "$state/log"
    ;;
esac
exit 0
SH
  cat > "$fb/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_CHROME_LOG:?}"
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=
previous=
for arg in "$@"; do
  if [ "$previous" = -t ]; then
    target=$arg
    previous=
  else
    previous=$arg
  fi
done
is_live() {
  [ "${FM_FAKE_TMUX_LIVE:-0}" = 1 ] || [ -n "${FM_FAKE_TMUX_LIVE_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_LIVE_TARGET" ]
}
case "${1:-}" in
  display-message)
    is_live || exit 1
    printf '%%1\n'
    ;;
  current-command)
    if [ -n "${FM_FAKE_TMUX_LIVE_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_LIVE_TARGET" ]; then
      printf '%s\n' "${FM_FAKE_TMUX_LIVE_COMMAND:-codex}"
    else
      printf '%s\n' "${FM_FAKE_TMUX_COMMAND:-bash}"
    fi
    ;;
  list-sessions)
    if [ "${FM_FAKE_TMUX_LIVE:-0}" = 1 ]; then
      printf 'fleet: 1 windows\n'
    else
      printf 'no server running\n' >&2
      exit 1
    fi
    ;;
  has-session)
    [ "${FM_FAKE_TMUX_LIVE:-0}" = 1 ]
    ;;
esac
exit 0
SH
  chmod +x "$fb/docker" "$fb/chrome-devtools-axi" "$fb/tmux"
  printf '%s\n' "$fb"
}

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

prepare_task() {
  local home=$1 id=$2 tasktmp=$3 backend=${4:-tmux} endpoint=${5:-fleet:fm-$2} browser=${6:-0}
  FM_HOME="$home" FM_ROOT="$ROOT" PATH="$FAKEBIN:$PATH" \
    fm_resource_prepare_task "$id" "$home" "$ROOT" "$home/state" "$tasktmp" "$backend" "$endpoint" "$browser"
}

test_labels_and_teardown_cleanup() {
  local home id tasktmp manifest owner
  home=$(new_home label-cleanup)
  id=resource-task
  tasktmp="$TMP_ROOT/fm-$id"
  manifest=$(prepare_task "$home" "$id" "$tasktmp" tmux fleet:fm-resource-task 1)
  owner=$(fm_resource_manifest_get "$manifest" owner)
  [ -n "$owner" ] || fail "resource manifest did not record an owner"
  [ "$(fm_resource_marker_get "$tasktmp/.fm-resource-owner" owner)" = "$owner" ] \
    || fail "task temp root owner marker did not match the manifest"
  [ "$(fm_resource_marker_get "$tasktmp/chrome-profile/.fm-resource-owner" owner)" = "$owner" ] \
    || fail "Chrome profile owner marker did not match the manifest"
  ( set -u; eval "$(fm_resource_task_env_line "$manifest")"; "$tasktmp/bin/docker" run postgres ) \
    || fail "task Docker wrapper failed"
  grep -F -- "--label com.firstmate.owner=$owner" "$DOCKER_STATE/log" >/dev/null \
    || fail "Docker wrapper did not add the exact owner label"
  ( set -u; eval "$(fm_resource_task_env_line "$manifest")"; "$tasktmp/bin/docker" network create task-net ) \
    || fail "task Docker network wrapper failed"
  ( set -u; eval "$(fm_resource_task_env_line "$manifest")"; "$tasktmp/bin/docker" volume create task-volume ) \
    || fail "task Docker volume wrapper failed"
  touch "$manifest.docker-used" "$manifest.chrome-used"
  ( set -u; eval "$(fm_resource_task_env_line "$manifest")"; "$tasktmp/bin/chrome-devtools-axi" open https://example.invalid ) \
    || fail "task Chrome wrapper failed"
  FM_HOME="$home" FM_ROOT="$ROOT" PATH="$FAKEBIN:$PATH" FM_FAKE_DOCKER_STATE="$DOCKER_STATE" FM_FAKE_DOCKER_OWNER="$owner" \
    FM_FAKE_CHROME_LOG="$CHROME_LOG" fm_resource_cleanup_task "$id" "$home" "$ROOT" "$home/state" "$tasktmp" "$manifest" \
    >/dev/null || fail "resource cleanup failed for a fully tagged task"
  [ ! -e "$tasktmp" ] || fail "tagged task temp root survived cleanup"
  [ ! -e "$manifest" ] || fail "resource manifest survived cleanup"
  [ -e "$DOCKER_STATE/removed" ] || fail "tagged Docker resource was not removed"
  grep -qxF 'stop' "$CHROME_LOG" || fail "tagged Chrome session was not stopped"
  pass "tagged Docker, Chrome, and profile resources are cleaned by owner"
}

test_untagged_temp_is_preserved() {
  local home id tasktmp owner
  home=$(new_home untagged)
  id=resource-untagged
  tasktmp="$TMP_ROOT/fm-$id"
  mkdir -p "$tasktmp"
  owner=$(fm_resource_owner_for "$home" "$ROOT" "$id")
  if fm_resource_remove_task_tmp "$id" "$tasktmp" "$owner" >/dev/null 2>&1; then
    fail "untagged temp cleanup should fail closed without an error path"
  fi
  [ -d "$tasktmp" ] || fail "cleanup removed a temp root without an owner marker"
  pass "untagged temp roots are preserved"
}

test_mismatched_docker_owner_is_preserved() {
  local home owner project
  home=$(new_home mismatched-docker)
  owner=$(fm_resource_owner_for "$home" "$ROOT" resource-mismatch)
  project=$(fm_resource_compose_project_for "$home" "$ROOT" resource-mismatch)
  rm -f "$DOCKER_STATE/removed"
  touch "$DOCKER_STATE/has-container" "$DOCKER_STATE/has-resource"
  if FM_FAKE_DOCKER_OWNER=firstmate:some-other-task FM_FAKE_DOCKER_STATE="$DOCKER_STATE" PATH="$FAKEBIN:$PATH" \
    fm_resource_docker_cleanup "$owner" resource-mismatch "$project" 1 >/dev/null 2>&1; then
    fail "Docker cleanup accepted a mismatched owner"
  fi
  [ ! -e "$DOCKER_STATE/removed" ] || fail "Docker cleanup removed a resource with a mismatched owner"
  [ -e "$DOCKER_STATE/has-container" ] || fail "Docker mismatch fixture was unexpectedly removed"
  rm -f "$DOCKER_STATE/has-container" "$DOCKER_STATE/has-resource"
  pass "mismatched Docker ownership is preserved"
}

test_gc_requires_dead_owner() {
  local home dead_id live_id dead_tmp live_tmp dead_manifest live_manifest out
  home=$(new_home gc)
  rm -f "$DOCKER_STATE/removed"
  dead_id=resource-dead
  live_id=resource-live
  dead_tmp="$TMP_ROOT/fm-$dead_id"
  live_tmp="$TMP_ROOT/fm-$live_id"
  dead_manifest=$(prepare_task "$home" "$dead_id" "$dead_tmp")
  live_manifest=$(prepare_task "$home" "$live_id" "$live_tmp")
  FM_FAKE_TMUX_LIVE=0 FM_FAKE_TMUX_LIVE_TARGET="fleet:fm-$live_id" FM_FAKE_TMUX_LIVE_COMMAND=codex \
    FM_FAKE_DOCKER_STATE="$DOCKER_STATE" FM_FAKE_CHROME_LOG="$CHROME_LOG" \
    FM_HOME="$home" FM_ROOT="$ROOT" PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-resource-gc.sh" >/dev/null \
    || fail "orphan GC failed for a provably dead owner"
  [ ! -e "$dead_manifest" ] || fail "orphan GC kept the dead owner's manifest"
  [ -e "$live_manifest" ] || fail "orphan GC removed a manifest without a live-owner proof"
  out=$(FM_FAKE_TMUX_LIVE=1 FM_FAKE_TMUX_COMMAND=codex FM_HOME="$home" FM_ROOT="$ROOT" PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-resource-gc.sh" --dry-run)
  printf '%s\n' "$out" | grep -F "resource-live" >/dev/null \
    || fail "GC dry-run did not preserve a live owner"
  [ -e "$live_tmp" ] || fail "GC removed the live owner's temp root"
  pass "orphan GC removes only resources whose owner is proven dead"
}

FAKEBIN=$(make_fakebin "$TMP_ROOT/fakes")
DOCKER_STATE="$TMP_ROOT/docker-state"
CHROME_LOG="$TMP_ROOT/chrome.log"
mkdir -p "$DOCKER_STATE"
: > "$CHROME_LOG"
export FAKEBIN DOCKER_STATE CHROME_LOG
export FM_FAKE_DOCKER_STATE="$DOCKER_STATE" FM_FAKE_CHROME_LOG="$CHROME_LOG"

test_labels_and_teardown_cleanup
test_untagged_temp_is_preserved
test_mismatched_docker_owner_is_preserved
test_gc_requires_dead_owner
