#!/usr/bin/env bash
# Sweep task-owned resources after the recorded endpoint is proven gone.
# Usage: fm-resource-gc.sh [--dry-run]
# Live, unverified, and unsupported endpoints retain their manifests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DRY_RUN=0

case "${1:-}" in
  '') ;;
  --dry-run) DRY_RUN=1 ;;
  -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
  *) echo "usage: fm-resource-gc.sh [--dry-run]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || exit 2
[ -d "$STATE" ] || exit 0

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-resource-lib.sh
. "$SCRIPT_DIR/fm-resource-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

endpoint_is_gone() {
  local backend=$1 target=$2 id=$3 meta=$4 session windows rc
  case "$backend" in
    tmux)
      session=${target%%:*}
      [ -n "$session" ] && [ "${target#*:}" = "fm-$id" ] || return 1
      fm_backend_source tmux || return 1
      rc=0
      windows=$(fm_backend_tmux_window_inventory "=$session") || rc=$?
      if [ "$rc" = 2 ]; then return 0; fi
      [ "$rc" = 0 ] || return 1
      if ! grep -Fxq -- "fm-$id" <<< "$windows"; then return 0; fi
      [ -f "$meta" ] && [ "$(fm_backend_agent_alive tmux "$target")" = dead ] || return 1
      [ "$DRY_RUN" = 0 ] || return 0
      fm_backend_kill tmux "$target" || return 1
      rc=0
      windows=$(fm_backend_tmux_window_inventory "=$session") || rc=$?
      [ "$rc" = 2 ] || { [ "$rc" = 0 ] && ! grep -Fxq -- "fm-$id" <<< "$windows"; }
      ;;
    herdr)
      # A live pane belongs to the presentation-lock close path in teardown.
      # The structured gone proof refuses an unreachable session.
      fm_backend_source herdr && fm_backend_herdr_endpoint_confirmed_gone "$target"
      ;;
    *) return 1 ;;
  esac
}

sweep_manifest() (
  local manifest=$1 id meta backend target control='' spawn='' meta_lock=''
  id=${manifest##*/}
  id=${id%.resources}
  fm_resource_valid_task_id "$id" || return 1
  if [ "$DRY_RUN" = 0 ]; then
    trap '[ -z "$meta_lock" ] || fm_lock_release "$meta_lock" || true; [ -z "$spawn" ] || fm_lock_release "$spawn" || true; [ -z "$control" ] || fm_lock_release "$control" || true' EXIT
    fm_lock_try_acquire "$STATE/.control-$id.lock" || return 0
    control="$STATE/.control-$id.lock"
    fm_lock_try_acquire "$STATE/.spawn-$id.lock" || return 0
    spawn="$STATE/.spawn-$id.lock"
    fm_lock_try_acquire "$STATE/.meta-$id.lock" || return 0
    meta_lock="$STATE/.meta-$id.lock"
  fi
  [ -e "$manifest" ] || [ -L "$manifest" ] || return 0
  if ! fm_resource_validate_manifest "$id" "$STATE" "$manifest" 1 \
    || [ "$(fm_resource_manifest_get "$manifest" home)" != "$(fm_resource_real_dir "$FM_HOME")" ] \
    || [ "$(fm_resource_manifest_get "$manifest" root)" != "$(fm_resource_real_dir "$FM_ROOT")" ]; then
    echo "resource: preserving $manifest because ownership cannot be proven" >&2
    return 1
  fi
  backend=$(fm_resource_manifest_get "$manifest" current_backend)
  target=$(fm_resource_manifest_get "$manifest" current_endpoint)
  meta="$STATE/$id.meta"
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    fm_backend_validate_task_endpoint "$meta" "$id" || return 1
    [ "$FM_BACKEND_VALIDATED_BACKEND" = "$backend" ] && [ "$FM_BACKEND_VALIDATED_TARGET" = "$target" ] || {
      echo "resource: preserving $manifest because the recorded endpoint changed" >&2
      return 1
    }
  fi
  if ! endpoint_is_gone "$backend" "$target" "$id" "$meta"; then
    [ "$DRY_RUN" = 0 ] || printf 'resource: preserving %s (live or unverified endpoint)\n' "$id"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    printf 'resource: orphan eligible for cleanup %s\n' "$id"
  else
    fm_resource_cleanup_task "$id" "$FM_HOME" "$FM_ROOT" "$STATE" "" "$manifest" || return 1
    printf 'resource: orphan cleanup complete for %s\n' "$id"
  fi
)

rc=0
for manifest in "$STATE"/*.resources; do
  [ -e "$manifest" ] || [ -L "$manifest" ] || continue
  sweep_manifest "$manifest" || rc=1
done
exit "$rc"
