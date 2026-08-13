#!/usr/bin/env bash
# Add firstmate ownership labels to Docker resources created by a task.
# The wrapper is installed only inside a task-owned temporary root.
set -eu

REAL_DOCKER=${FM_RESOURCE_REAL_DOCKER:-}
[ -n "$REAL_DOCKER" ] && [ -x "$REAL_DOCKER" ] && [ "$REAL_DOCKER" != "$0" ] || {
  echo "error: firstmate Docker wrapper has no safe real Docker executable" >&2
  exit 127
}

owner=${FM_TASK_RESOURCE_OWNER:-}
task=${FM_TASK_ID:-}
home=${FM_TASK_RESOURCE_HOME_TAG:-}
backend=${FM_TASK_RESOURCE_BACKEND:-}
endpoint=${FM_TASK_RESOURCE_ENDPOINT:-}
manifest=${FM_TASK_RESOURCE_MANIFEST:-}
labels=()
if [ -n "$owner" ] && [ -n "$task" ] && [ -n "$home" ]; then
  labels+=(--label "com.firstmate.owner=$owner")
  labels+=(--label "com.firstmate.task=$task")
  labels+=(--label "com.firstmate.home=$home")
  [ -n "$backend" ] && labels+=(--label "com.firstmate.backend=$backend")
  [ -n "$endpoint" ] && labels+=(--label "com.firstmate.endpoint=$endpoint")
fi

mark_used() {
  [ -n "$manifest" ] || return 0
  : > "$manifest.docker-used" 2>/dev/null || true
}

case "${1:-}" in
  run|create)
    mark_used
    exec "$REAL_DOCKER" "$1" "${labels[@]}" "${@:2}"
    ;;
  container)
    case "${2:-}" in
      run|create)
        mark_used
        exec "$REAL_DOCKER" container "$2" "${labels[@]}" "${@:3}"
        ;;
    esac
    ;;
  service)
    if [ "${2:-}" = create ]; then
      mark_used
      exec "$REAL_DOCKER" service create "${labels[@]}" "${@:3}"
    fi
    ;;
  network)
    if [ "${2:-}" = create ]; then
      mark_used
      exec "$REAL_DOCKER" network create "${labels[@]}" "${@:3}"
    fi
    ;;
  volume)
    if [ "${2:-}" = create ]; then
      mark_used
      exec "$REAL_DOCKER" volume create "${labels[@]}" "${@:3}"
    fi
    ;;
  compose)
    case "${2:-}" in
      up|run|create)
        mark_used
        ;;
    esac
    ;;
esac

exec "$REAL_DOCKER" "$@"
