#!/usr/bin/env bash
# Record use of a task-owned chrome-devtools-axi session before forwarding it.
# The wrapper is installed only inside a task-owned temporary root.
set -eu

INVOKED_PATH=${BASH_SOURCE[0]}
TASK_TMP=$(cd "$(dirname "$INVOKED_PATH")/.." && pwd -P)
SOURCE_PATH=$INVOKED_PATH
if [ -L "$SOURCE_PATH" ]; then
  SOURCE_PATH=$(readlink "$SOURCE_PATH")
fi
SCRIPT_DIR=$(cd "$(dirname "$SOURCE_PATH")" && pwd -P)
# shellcheck source=bin/fm-resource-lib.sh
. "$SCRIPT_DIR/fm-resource-lib.sh"

REAL_CHROME=${FM_RESOURCE_REAL_CHROME:-}
[ -n "$REAL_CHROME" ] && [ -x "$REAL_CHROME" ] && [ "$REAL_CHROME" != "$0" ] || {
  echo "error: firstmate Chrome wrapper has no safe real executable" >&2
  exit 127
}

manifest=${FM_TASK_RESOURCE_MANIFEST:-}
manifest_task=$(fm_resource_manifest_get "$manifest" task)
task=$manifest_task
fm_resource_valid_task_id "$task" || {
  echo "error: firstmate Chrome wrapper has no valid task identity" >&2
  exit 1
}
marker="$TASK_TMP/$FM_RESOURCE_OWNER_MARKER"
[ -f "$marker" ] && [ ! -L "$marker" ] || {
  echo "error: firstmate Chrome wrapper has no task owner marker" >&2
  exit 1
}
manifest_state=$(fm_resource_manifest_get "$manifest" state)
fm_resource_validate_manifest "$task" "$manifest_state" "$manifest" || {
  echo "error: firstmate Chrome wrapper has no matching durable resource manifest" >&2
  exit 1
}
owner=$(fm_resource_manifest_get "$manifest" owner)
marker_owner=$(fm_resource_marker_get "$marker" owner)
marker_task=$(fm_resource_marker_get "$marker" task)
[ "$manifest_task" = "$task" ] && [ "$marker_owner" = "$owner" ] && [ "$marker_task" = "$task" ] || {
  echo "error: firstmate Chrome wrapper ownership identity does not match its task" >&2
  exit 1
}
fm_resource_validate_task_tmp "$task" "$TASK_TMP" "$owner" \
  "$(fm_resource_manifest_get "$manifest" home)" \
  "$(fm_resource_manifest_get "$manifest" root)" \
  "$(fm_resource_manifest_get "$manifest" home_tag)" >/dev/null || {
  echo "error: firstmate Chrome wrapper is outside its owned task temp root" >&2
  exit 1
}
session=$(fm_resource_manifest_get "$manifest" chrome_session)
profile=$(fm_resource_manifest_get "$manifest" chrome_profile)
uses_browser=1
case "${1:-}" in
  --help|-h|--version|-V) uses_browser=0 ;;
esac
if [ "$uses_browser" = 1 ]; then
  [ -n "$owner" ] && [ -n "$session" ] && [ -n "$profile" ] || {
    echo "error: firstmate Chrome wrapper has no task-owned browser identity" >&2
    exit 1
  }
  [ -n "$manifest" ] && [ -f "$manifest" ] && [ ! -L "$manifest" ] || {
    echo "error: firstmate Chrome wrapper has no durable resource manifest" >&2
    exit 1
  }
  : > "$manifest.chrome-used" 2>/dev/null || {
    echo "error: cannot record Chrome use in $manifest" >&2
    exit 1
  }
fi

exec env \
  CHROME_DEVTOOLS_AXI_SESSION="$session" \
  CHROME_DEVTOOLS_AXI_USER_DATA_DIR="$profile" \
  FM_RESOURCE_CHROME_OWNER="$owner" \
  "$REAL_CHROME" "$@"
