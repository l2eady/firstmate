#!/usr/bin/env bash
# Sweep task-owned resources whose firstmate owner is provably dead.
# Usage: fm-resource-gc.sh [--dry-run]
# The command never removes an untagged resource or acts on an unknown owner.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DRY_RUN=0

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  --dry-run) DRY_RUN=1 ;;
  *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
esac

# shellcheck source=bin/fm-resource-lib.sh
. "$SCRIPT_DIR/fm-resource-lib.sh"

[ -d "$STATE" ] || exit 0
rc=0
for manifest in "$STATE"/*.resources; do
  [ -f "$manifest" ] || continue
  if [ -L "$manifest" ]; then
    echo "resource: preserving symbolic-link manifest $manifest" >&2
    rc=1
    continue
  fi
  id=$(basename "$manifest" .resources)
  owner=$(fm_resource_manifest_get "$manifest" owner)
  resource_home=$(fm_resource_manifest_get "$manifest" home)
  resource_root=$(fm_resource_manifest_get "$manifest" root)
  if ! fm_resource_validate_manifest "$id" "$STATE" "$manifest" 1; then
    echo "resource: preserving manifest $manifest because ownership or endpoint identity cannot be proven" >&2
    rc=1
    continue
  fi
  meta="$STATE/$id.meta"
  if ! fm_resource_owner_is_dead "$meta" "$manifest"; then
    echo "resource: preserving $owner because its owner is live or liveness is unknown"
    continue
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo "resource: orphan eligible for cleanup $owner"
    continue
  fi
  if ! fm_resource_endpoint_cleanup "$id" "$resource_home" "$resource_root" "$meta" "$manifest"; then
    rc=1
    continue
  fi
  if fm_resource_cleanup_task "$id" "$resource_home" "$resource_root" "$STATE" "" "$manifest"; then
    echo "resource: orphan cleanup complete for $owner"
  else
    rc=1
  fi
done
exit "$rc"
