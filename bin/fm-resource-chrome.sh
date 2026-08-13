#!/usr/bin/env bash
# Record use of a task-owned chrome-devtools-axi session before forwarding it.
# The wrapper is installed only inside a task-owned temporary root.
set -eu

REAL_CHROME=${FM_RESOURCE_REAL_CHROME:-}
[ -n "$REAL_CHROME" ] && [ -x "$REAL_CHROME" ] && [ "$REAL_CHROME" != "$0" ] || {
  echo "error: firstmate Chrome wrapper has no safe real executable" >&2
  exit 127
}

manifest=${FM_TASK_RESOURCE_MANIFEST:-}
if [ "${1:-}" != --help ] && [ "${1:-}" != -h ] && [ "${1:-}" != --version ] && [ "${1:-}" != -V ] && [ "${1:-}" != stop ]; then
  [ -n "$manifest" ] && : > "$manifest.chrome-used" 2>/dev/null || true
fi

exec env \
  CHROME_DEVTOOLS_AXI_SESSION="${FM_RESOURCE_CHROME_SESSION:-}" \
  CHROME_DEVTOOLS_AXI_USER_DATA_DIR="${FM_RESOURCE_CHROME_PROFILE:-}" \
  "$REAL_CHROME" "$@"
