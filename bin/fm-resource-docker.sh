#!/usr/bin/env bash
# Add firstmate ownership labels to Docker resources created by a task.
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

REAL_DOCKER=${FM_RESOURCE_REAL_DOCKER:-}
[ -n "$REAL_DOCKER" ] && [ -x "$REAL_DOCKER" ] && [ "$REAL_DOCKER" != "$0" ] || {
  echo "error: firstmate Docker wrapper has no safe real Docker executable" >&2
  exit 127
}

manifest=${FM_TASK_RESOURCE_MANIFEST:-}
manifest_task=$(fm_resource_manifest_get "$manifest" task)
task=$manifest_task
fm_resource_valid_task_id "$task" || {
  echo "error: firstmate Docker wrapper has no valid task identity" >&2
  exit 1
}
marker="$TASK_TMP/$FM_RESOURCE_OWNER_MARKER"
[ -f "$marker" ] && [ ! -L "$marker" ] || {
  echo "error: firstmate Docker wrapper has no task owner marker" >&2
  exit 1
}
manifest_state=$(fm_resource_manifest_get "$manifest" state)
fm_resource_validate_manifest "$task" "$manifest_state" "$manifest" || {
  echo "error: firstmate Docker wrapper has no matching durable resource manifest" >&2
  exit 1
}
owner=$(fm_resource_manifest_get "$manifest" owner)
marker_owner=$(fm_resource_marker_get "$marker" owner)
marker_task=$(fm_resource_marker_get "$marker" task)
[ "$manifest_task" = "$task" ] && [ "$marker_owner" = "$owner" ] && [ "$marker_task" = "$task" ] || {
  echo "error: firstmate Docker wrapper ownership identity does not match its task" >&2
  exit 1
}
fm_resource_validate_task_tmp "$task" "$TASK_TMP" "$owner" \
  "$(fm_resource_manifest_get "$manifest" home)" \
  "$(fm_resource_manifest_get "$manifest" root)" \
  "$(fm_resource_manifest_get "$manifest" home_tag)" >/dev/null || {
  echo "error: firstmate Docker wrapper is outside its owned task temp root" >&2
  exit 1
}
home=$(fm_resource_manifest_get "$manifest" home_tag)
backend=$(fm_resource_manifest_get "$manifest" backend)
endpoint=$(fm_resource_manifest_get "$manifest" endpoint)
project=$(fm_resource_manifest_get "$manifest" docker_project)
labels=()
if [ -n "$owner" ] && [ -n "$task" ] && [ -n "$home" ]; then
  labels+=(--label "com.firstmate.owner=$owner")
  labels+=(--label "com.firstmate.task=$task")
  labels+=(--label "com.firstmate.home=$home")
  [ -n "$backend" ] && labels+=(--label "com.firstmate.backend=$backend")
  [ -n "$endpoint" ] && labels+=(--label "com.firstmate.endpoint=$endpoint")
fi

mark_used() {
  local resource_kind=${1:-}
  [ -n "$manifest" ] && [ -f "$manifest" ] && [ ! -L "$manifest" ] || {
    echo "error: firstmate Docker wrapper has no durable resource manifest" >&2
    return 1
  }
  : > "$manifest.docker-used" 2>/dev/null || {
    echo "error: cannot record Docker use in $manifest" >&2
    return 1
  }
  if [ "$resource_kind" = service ]; then
    : > "$manifest.docker-service-used" 2>/dev/null || {
      echo "error: cannot record Docker service use in $manifest" >&2
      return 1
    }
  fi
}

require_labels() {
  [ "${#labels[@]}" -gt 0 ] || {
    echo "error: firstmate Docker resource creation lacks ownership identity" >&2
    return 1
  }
}

reject_reserved_labels() {
  local expect_value=0 arg
  for arg in "$@"; do
    if [ "$expect_value" = 1 ]; then
      case "$arg" in
        com.firstmate.*) echo "error: task cannot override firstmate Docker labels" >&2; return 1 ;;
      esac
      expect_value=0
      continue
    fi
    case "$arg" in
      --label)
        expect_value=1
        ;;
      --label=com.firstmate.*)
        echo "error: task cannot override firstmate Docker labels" >&2
        return 1
        ;;
      -l)
        expect_value=1
        ;;
      -lcom.firstmate.*)
        echo "error: task cannot override firstmate Docker labels" >&2
        return 1
        ;;
    esac
  done
}

compose_project_matches() {
  local expect_value=0 arg explicit=
  [ -n "$project" ] || {
    echo "error: firstmate Docker wrapper has no generated Compose project" >&2
    return 1
  }
  [ "${COMPOSE_PROJECT_NAME:-$project}" = "$project" ] || {
    echo "error: task cannot override the firstmate Compose project '$project' through the environment" >&2
    return 1
  }
  for arg in "$@"; do
    if [ "$expect_value" = 1 ]; then
      explicit=$arg
      expect_value=0
      continue
    fi
    case "$arg" in
      -p|--project-name)
        expect_value=1
        ;;
      -p*)
        explicit=${arg#-p}
        ;;
      --project-name=*)
        explicit=${arg#--project-name=}
        ;;
    esac
  done
  if [ -n "$explicit" ] && [ "$explicit" != "$project" ]; then
    echo "error: task cannot override the firstmate Compose project '$project'" >&2
    return 1
  fi
}

compose_subcommand() {
  local skip_value=0 arg
  for arg in "$@"; do
    if [ "$skip_value" = 1 ]; then
      skip_value=0
      continue
    fi
    case "$arg" in
      -f|--file|-p|--project-name|--env-file|--profile)
        skip_value=1
        continue
        ;;
      --*=*)
        continue
        ;;
      -*)
        continue
        ;;
      *)
        printf '%s' "$arg"
        return 0
        ;;
    esac
  done
}

case "${1:-}" in
  run|create)
    require_labels
    reject_reserved_labels "${@:2}"
    mark_used
    exec "$REAL_DOCKER" "$1" "${labels[@]}" "${@:2}"
    ;;
  container)
    case "${2:-}" in
      run|create)
        require_labels
        reject_reserved_labels "${@:3}"
        mark_used
        exec "$REAL_DOCKER" container "$2" "${labels[@]}" "${@:3}"
        ;;
    esac
    ;;
  service)
    if [ "${2:-}" = create ]; then
      require_labels
      reject_reserved_labels "${@:3}"
      mark_used service
      exec "$REAL_DOCKER" service create "${labels[@]}" "${@:3}"
    fi
    ;;
  network)
    if [ "${2:-}" = create ]; then
      require_labels
      reject_reserved_labels "${@:3}"
      mark_used
      exec "$REAL_DOCKER" network create "${labels[@]}" "${@:3}"
    fi
    ;;
  volume)
    if [ "${2:-}" = create ]; then
      require_labels
      reject_reserved_labels "${@:3}"
      mark_used
      exec "$REAL_DOCKER" volume create "${labels[@]}" "${@:3}"
    fi
    ;;
  compose)
    subcommand=$(compose_subcommand "${@:2}")
    case "$subcommand" in
      up|run|create|scale)
        require_labels
        compose_project_matches "${@:2}"
        mark_used
        ;;
    esac
    ;;
esac

exec "$REAL_DOCKER" "$@"
