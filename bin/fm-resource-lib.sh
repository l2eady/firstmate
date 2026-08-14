#!/usr/bin/env bash
# Shared task-resource ownership, cleanup, and orphan-detection primitives.
# This file is sourced by fm-spawn.sh, fm-teardown.sh, and fm-resource-gc.sh.
# The ownership contract is documented in docs/teardown-resource-cleanup.md.

_FM_RESOURCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$_FM_RESOURCE_LIB_DIR/fm-backend-hometag-lib.sh"

if ! declare -F fm_backend_of_meta >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backend.sh
  . "$_FM_RESOURCE_LIB_DIR/fm-backend.sh"
fi

FM_RESOURCE_OWNER_LABEL="com.firstmate.owner"
FM_RESOURCE_TASK_LABEL="com.firstmate.task"
FM_RESOURCE_HOME_LABEL="com.firstmate.home"
FM_RESOURCE_BACKEND_LABEL="com.firstmate.backend"
FM_RESOURCE_ENDPOINT_LABEL="com.firstmate.endpoint"
FM_RESOURCE_OWNER_MARKER=".fm-resource-owner"
FM_RESOURCE_MANIFEST_SUFFIX=".resources"

fm_resource_valid_task_id() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_resource_home_tag_for() {  # <home> <root>
  local home=$1 root=$2
  (
    FM_HOME=$home
    FM_ROOT=$root
    fm_backend_hometag
  )
}

fm_resource_owner_for() {  # <home> <root> <task-id>
  local home=$1 root=$2 id=$3 tag
  fm_resource_valid_task_id "$id" || return 1
  tag=$(fm_resource_home_tag_for "$home" "$root") || return 1
  printf 'firstmate:%s:%s' "$tag" "$id"
}

fm_resource_compose_project_for() {  # <home> <root> <task-id>
  local home=$1 root=$2 id=$3 tag
  fm_resource_valid_task_id "$id" || return 1
  tag=$(fm_resource_home_tag_for "$home" "$root") || return 1
  tag=$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '_')
  id=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '_')
  printf 'fm-%s-%s' "$tag" "$id"
}

fm_resource_chrome_session_for() {  # <home> <root> <task-id>
  local home=$1 root=$2 id=$3 tag
  tag=$(fm_resource_home_tag_for "$home" "$root") || return 1
  printf 'fm-%s-%s' "$tag" "$id"
}

fm_resource_manifest_get() {  # <manifest> <key>
  local manifest=$1 key=$2
  [ -f "$manifest" ] || return 0
  grep "^$key=" "$manifest" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_resource_marker_get() {  # <marker> <key>
  fm_resource_manifest_get "$1" "$2"
}

fm_resource_validate_manifest() {  # <task-id> <state-dir> <manifest> [require-endpoint]
  local id=$1 state=$2 manifest=$3 require_endpoint=${4:-0}
  local state_abs expected manifest_dir manifest_base version task home root recorded_state tag owner expected_owner backend endpoint calculated_tag
  fm_resource_valid_task_id "$id" || return 1
  state_abs=$(fm_resource_real_dir "$state") || return 1
  manifest_dir=$(fm_resource_real_dir "$(dirname "$manifest")") || return 1
  manifest_base=$(basename "$manifest")
  expected="$state_abs/$id$FM_RESOURCE_MANIFEST_SUFFIX"
  [ "$manifest_dir/$manifest_base" = "$expected" ] || return 1
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
  version=$(fm_resource_manifest_get "$manifest" version)
  task=$(fm_resource_manifest_get "$manifest" task)
  home=$(fm_resource_manifest_get "$manifest" home)
  root=$(fm_resource_manifest_get "$manifest" root)
  recorded_state=$(fm_resource_manifest_get "$manifest" state)
  tag=$(fm_resource_manifest_get "$manifest" home_tag)
  owner=$(fm_resource_manifest_get "$manifest" owner)
  [ "$version" = 1 ] && [ "$task" = "$id" ] && [ -n "$home" ] && [ -n "$root" ] \
    && [ "$recorded_state" = "$state_abs" ] && [ -n "$tag" ] || return 1
  home=$(fm_resource_real_dir "$home") || return 1
  root=$(fm_resource_real_dir "$root") || return 1
  [ "$home" = "$(fm_resource_manifest_get "$manifest" home)" ] \
    && [ "$root" = "$(fm_resource_manifest_get "$manifest" root)" ] || return 1
  calculated_tag=$(fm_resource_home_tag_for "$home" "$root") || return 1
  [ "$tag" = "$calculated_tag" ] || return 1
  expected_owner=$(fm_resource_owner_for "$home" "$root" "$id") || return 1
  [ "$owner" = "$expected_owner" ] || return 1
  if [ "$require_endpoint" = 1 ]; then
    backend=$(fm_resource_manifest_get "$manifest" backend)
    endpoint=$(fm_resource_manifest_get "$manifest" endpoint)
    [ -n "$backend" ] && [ -n "$endpoint" ] || return 1
    fm_backend_validate "$backend" || return 1
  fi
}

fm_resource_shell_quote() {  # <value>
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_resource_real_dir() {  # <path>
  local path=$1
  [ -d "$path" ] || return 1
  (cd "$path" && pwd -P)
}

fm_resource_prepare_task() {  # <id> <home> <root> <state> <tasktmp> <backend> <endpoint> <browser-owned>
  local id=$1 home=$2 root=$3 state=$4 tasktmp=$5 backend=$6 endpoint=$7 browser_owned=${8:-0}
  local home_abs root_abs state_abs owner tag compose chrome_session profile marker profile_marker manifest tmp
  local real_docker real_chrome docker_wrapper chrome_wrapper expected_wrapper existing_owner existing_task profile_owner profile_task umask_save child
  fm_resource_valid_task_id "$id" || {
    echo "error: invalid task id for resource ownership: $id" >&2
    return 1
  }
  home_abs=$(fm_resource_real_dir "$home") || {
    echo "error: resource owner home is not a directory: $home" >&2
    return 1
  }
  root_abs=$(fm_resource_real_dir "$root") || {
    echo "error: resource owner root is not a directory: $root" >&2
    return 1
  }
  mkdir -p "$state" || {
    echo "error: cannot create resource state directory: $state" >&2
    return 1
  }
  state_abs=$(fm_resource_real_dir "$state") || return 1
  owner=$(fm_resource_owner_for "$home_abs" "$root_abs" "$id") || return 1
  tag=$(fm_resource_home_tag_for "$home_abs" "$root_abs") || return 1
  compose=$(fm_resource_compose_project_for "$home_abs" "$root_abs" "$id") || return 1
  chrome_session=$(fm_resource_chrome_session_for "$home_abs" "$root_abs" "$id") || return 1
  profile="$tasktmp/chrome-profile"
  marker="$tasktmp/$FM_RESOURCE_OWNER_MARKER"
  manifest="$state_abs/$id$FM_RESOURCE_MANIFEST_SUFFIX"
  if [ -L "$manifest" ]; then
    echo "REFUSED: resource manifest is a symbolic link: $manifest" >&2
    return 1
  fi

  if [ -e "$tasktmp" ] || [ -L "$tasktmp" ]; then
    [ -d "$tasktmp" ] && [ ! -L "$tasktmp" ] || {
      echo "REFUSED: task temp root is not a real directory: $tasktmp" >&2
      return 1
    }
    existing_owner=$(fm_resource_marker_get "$marker" owner)
    existing_task=$(fm_resource_marker_get "$marker" task)
    if [ "$existing_owner" != "$owner" ] || [ "$existing_task" != "$id" ]; then
      echo "REFUSED: task temp root $tasktmp has no matching firstmate owner marker" >&2
      return 1
    fi
  else
    mkdir -p "$tasktmp" || return 1
  fi
  for child in "$tasktmp/gotmp" "$tasktmp/bin" "$profile"; do
    if [ -L "$child" ] || { [ -e "$child" ] && [ ! -d "$child" ]; }; then
      echo "REFUSED: task resource path is not a real directory: $child" >&2
      return 1
    fi
  done
  profile_marker="$profile/$FM_RESOURCE_OWNER_MARKER"
  if { [ -e "$profile" ] && [ -e "$profile_marker" ]; } || [ -L "$profile_marker" ]; then
    [ -f "$profile_marker" ] && [ ! -L "$profile_marker" ] || {
      echo "REFUSED: Chrome profile owner marker is not a regular file: $profile_marker" >&2
      return 1
    }
    profile_owner=$(fm_resource_marker_get "$profile_marker" owner)
    profile_task=$(fm_resource_marker_get "$profile_marker" task)
    if [ "$profile_owner" != "$owner" ] || [ "$profile_task" != "$id" ]; then
      echo "REFUSED: Chrome profile $profile has no matching firstmate owner marker" >&2
      return 1
    fi
  elif [ -e "$profile" ]; then
    echo "REFUSED: existing Chrome profile has no matching firstmate owner marker: $profile" >&2
    return 1
  fi
  mkdir -p "$tasktmp/gotmp" "$tasktmp/bin" "$profile" || return 1

  if [ -L "$marker" ] || { [ -e "$marker" ] && [ ! -f "$marker" ]; }; then
    echo "REFUSED: task temp owner marker is not a regular file: $marker" >&2
    return 1
  fi
  if [ -L "$profile_marker" ] || { [ -e "$profile_marker" ] && [ ! -f "$profile_marker" ]; }; then
    echo "REFUSED: Chrome profile owner marker is not a regular file: $profile_marker" >&2
    return 1
  fi
  {
    echo "version=1"
    echo "owner=$owner"
    echo "task=$id"
    echo "home=$home_abs"
    echo "home_tag=$tag"
    echo "root=$root_abs"
    echo "resource=task"
  } > "$marker" || return 1
  {
    echo "version=1"
    echo "owner=$owner"
    echo "task=$id"
    echo "home=$home_abs"
    echo "home_tag=$tag"
    echo "root=$root_abs"
    echo "resource=chrome"
    echo "session=$chrome_session"
  } > "$profile_marker" || return 1

  real_docker=$(type -P docker 2>/dev/null || true)
  real_chrome=$(type -P chrome-devtools-axi 2>/dev/null || true)
  docker_wrapper="$_FM_RESOURCE_LIB_DIR/fm-resource-docker.sh"
  chrome_wrapper="$_FM_RESOURCE_LIB_DIR/fm-resource-chrome.sh"
  for child in "$tasktmp/bin/docker" "$tasktmp/bin/chrome-devtools-axi"; do
    case "$child" in
      */docker) expected_wrapper=$docker_wrapper ;;
      *) expected_wrapper=$chrome_wrapper ;;
    esac
    if [ -e "$child" ] || [ -L "$child" ]; then
      [ -L "$child" ] && [ "$(readlink "$child" 2>/dev/null || true)" = "$expected_wrapper" ] || {
        echo "REFUSED: task wrapper path is not a generated firstmate symlink: $child" >&2
        return 1
      }
    fi
  done
  rm -f "$tasktmp/bin/docker" "$tasktmp/bin/chrome-devtools-axi" || return 1
  if [ -n "$real_docker" ] && [ -x "$real_docker" ] && [ "$real_docker" != "$tasktmp/bin/docker" ]; then
    ln -s "$docker_wrapper" "$tasktmp/bin/docker" || return 1
  else
    real_docker=
  fi
  if [ "$browser_owned" = 1 ] && [ -n "$real_chrome" ] && [ -x "$real_chrome" ] && [ "$real_chrome" != "$tasktmp/bin/chrome-devtools-axi" ]; then
    ln -s "$chrome_wrapper" "$tasktmp/bin/chrome-devtools-axi" || return 1
  else
    real_chrome=
    browser_owned=0
  fi

  umask_save=$(umask)
  umask 077
  tmp="$manifest.tmp.$$"
  {
    echo "version=1"
    echo "owner=$owner"
    echo "task=$id"
    echo "home=$home_abs"
    echo "home_tag=$tag"
    echo "root=$root_abs"
    echo "state=$state_abs"
    echo "tasktmp=$tasktmp"
    echo "backend=$backend"
    echo "endpoint=$endpoint"
    echo "docker_project=$compose"
    echo "docker_real=$real_docker"
    echo "chrome_session=$chrome_session"
    echo "chrome_label=$chrome_session"
    echo "chrome_profile=$profile"
    echo "chrome_owned=$browser_owned"
    echo "chrome_real=$real_chrome"
  } > "$tmp"
  umask "$umask_save"
  mv -f "$tmp" "$manifest" || return 1
  printf '%s\n' "$manifest"
}

fm_resource_task_env_line() {  # <manifest>
  local manifest=$1 task owner home tag state tasktmp backend endpoint compose chrome_session chrome_label profile docker_real chrome_real chrome_owned
  task=$(fm_resource_manifest_get "$manifest" task)
  owner=$(fm_resource_manifest_get "$manifest" owner)
  home=$(fm_resource_manifest_get "$manifest" home)
  tag=$(fm_resource_manifest_get "$manifest" home_tag)
  state=$(fm_resource_manifest_get "$manifest" state)
  tasktmp=$(fm_resource_manifest_get "$manifest" tasktmp)
  backend=$(fm_resource_manifest_get "$manifest" backend)
  endpoint=$(fm_resource_manifest_get "$manifest" endpoint)
  compose=$(fm_resource_manifest_get "$manifest" docker_project)
  chrome_session=$(fm_resource_manifest_get "$manifest" chrome_session)
  chrome_label=$(fm_resource_manifest_get "$manifest" chrome_label)
  [ -n "$chrome_label" ] || chrome_label=$chrome_session
  profile=$(fm_resource_manifest_get "$manifest" chrome_profile)
  docker_real=$(fm_resource_manifest_get "$manifest" docker_real)
  chrome_real=$(fm_resource_manifest_get "$manifest" chrome_real)
  chrome_owned=$(fm_resource_manifest_get "$manifest" chrome_owned)
  [ -n "$task" ] && [ -n "$owner" ] && [ -n "$tasktmp" ] || return 1
  printf 'export FM_TASK_ID=%s FM_TASK_RESOURCE_OWNER=%s FM_TASK_RESOURCE_HOME=%s FM_TASK_RESOURCE_HOME_TAG=%s FM_TASK_RESOURCE_MANIFEST=%s FM_TASK_RESOURCE_STATE=%s FM_TASK_RESOURCE_BACKEND=%s FM_TASK_RESOURCE_ENDPOINT=%s FM_RESOURCE_DOCKER_PROJECT=%s FM_RESOURCE_CHROME_SESSION=%s FM_RESOURCE_CHROME_LABEL=%s FM_RESOURCE_CHROME_PROFILE=%s FM_RESOURCE_CHROME_OWNED=%s\n' \
    "$(fm_resource_shell_quote "$task")" "$(fm_resource_shell_quote "$owner")" "$(fm_resource_shell_quote "$home")" "$(fm_resource_shell_quote "$tag")" "$(fm_resource_shell_quote "$manifest")" "$(fm_resource_shell_quote "$state")" "$(fm_resource_shell_quote "$backend")" "$(fm_resource_shell_quote "$endpoint")" "$(fm_resource_shell_quote "$compose")" "$(fm_resource_shell_quote "$chrome_session")" "$(fm_resource_shell_quote "$chrome_label")" "$(fm_resource_shell_quote "$profile")" "$(fm_resource_shell_quote "$chrome_owned")"
  printf 'export PATH=%s:$PATH\n' "$(fm_resource_shell_quote "$(dirname "$tasktmp")/$(basename "$tasktmp")/bin")"
  printf 'export COMPOSE_PROJECT_NAME=%s FM_RESOURCE_REAL_DOCKER=%s FM_RESOURCE_REAL_CHROME=%s\n' \
    "$(fm_resource_shell_quote "$compose")" "$(fm_resource_shell_quote "$docker_real")" "$(fm_resource_shell_quote "$chrome_real")"
  if [ "$chrome_owned" = 1 ]; then
    printf 'export CHROME_DEVTOOLS_AXI_SESSION=%s CHROME_DEVTOOLS_AXI_USER_DATA_DIR=%s\n' "$(fm_resource_shell_quote "$chrome_session")" "$(fm_resource_shell_quote "$profile")"
  fi
}

fm_resource_validate_task_tmp() {  # <id> <tasktmp> <owner> [<home> <root> <home-tag>]
  local id=$1 tasktmp=$2 owner=$3 home=${4:-} root=${5:-} expected_tag=${6:-}
  local marker marker_owner marker_task marker_home marker_root marker_tag marker_version marker_resource abs base expected_base computed_tag parent base_abs home_abs root_abs
  [ -n "$tasktmp" ] || return 0
  [ -e "$tasktmp" ] || [ -L "$tasktmp" ] || return 0
  [ -d "$tasktmp" ] && [ ! -L "$tasktmp" ] || {
    echo "REFUSED: task temp root is not a real directory: $tasktmp" >&2
    return 1
  }
  abs=$(cd "$tasktmp" && pwd -P) || return 1
  base=$(basename "$abs")
  parent=$(dirname "$abs")
  base_abs=$(cd "$parent" && pwd -P) || return 1
  if [ -n "$home" ]; then
    home_abs=$(fm_resource_real_dir "$home") || return 1
  fi
  if [ -n "$root" ]; then
    root_abs=$(fm_resource_real_dir "$root") || return 1
  fi
  expected_base="fm-$id"
  if [ -n "$home" ] && [ -n "$root" ]; then
    computed_tag=$(fm_resource_home_tag_for "$home_abs" "$root_abs") || return 1
    expected_base="$expected_base-$computed_tag"
  fi
  if [ "$base" != "fm-$id" ] && [ "$base" != "$expected_base" ]; then
    echo "REFUSED: task temp root $tasktmp is not named for task $id" >&2
    return 1
  fi
  case "$base_abs" in
    /|"$abs")
      echo "REFUSED: task temp root parent is unsafe: $tasktmp" >&2
      return 1
      ;;
  esac
  if [ -n "$home" ]; then
    case "$abs" in
      "$home_abs"|"$home_abs"/*)
        echo "REFUSED: task temp root is inside the resource owner home: $tasktmp" >&2
        return 1
        ;;
    esac
  fi
  if [ -n "$root" ]; then
    case "$abs" in
      "$root_abs"|"$root_abs"/*)
        echo "REFUSED: task temp root is inside the resource owner root: $tasktmp" >&2
        return 1
        ;;
    esac
  fi
  marker="$abs/$FM_RESOURCE_OWNER_MARKER"
  if [ -L "$marker" ]; then
    echo "REFUSED: task temp owner marker is not a regular file: $marker" >&2
    return 1
  fi
  [ -f "$marker" ] || {
    echo "resource: preserving untagged task temp root $tasktmp" >&2
    return 2
  }
  marker_version=$(fm_resource_marker_get "$marker" version)
  marker_owner=$(fm_resource_marker_get "$marker" owner)
  marker_task=$(fm_resource_marker_get "$marker" task)
  marker_home=$(fm_resource_marker_get "$marker" home)
  marker_root=$(fm_resource_marker_get "$marker" root)
  marker_tag=$(fm_resource_marker_get "$marker" home_tag)
  marker_resource=$(fm_resource_marker_get "$marker" resource)
  if [ "$marker_version" != 1 ] || [ "$marker_owner" != "$owner" ] || [ "$marker_task" != "$id" ] || [ "$marker_resource" != task ]; then
    echo "resource: preserving untagged task temp root $tasktmp" >&2
    return 2
  fi
  if [ -n "$home" ] && [ "$marker_home" != "$home_abs" ]; then
    echo "resource: preserving task temp root with mismatched owner home $tasktmp" >&2
    return 2
  fi
  if [ -n "$root" ] && [ "$marker_root" != "$root_abs" ]; then
    echo "resource: preserving task temp root with mismatched owner root $tasktmp" >&2
    return 2
  fi
  if [ -n "$expected_tag" ] && [ "$marker_tag" != "$expected_tag" ]; then
    echo "resource: preserving task temp root with mismatched owner tag $tasktmp" >&2
    return 2
  fi
  printf '%s\n' "$abs"
}

fm_resource_remove_task_tmp() {  # <id> <tasktmp> <owner> [<home> <root> <home-tag>]
  local id=$1 tasktmp=$2 owner=$3 home=${4:-} root=${5:-} expected_tag=${6:-} abs rc
  [ -n "$tasktmp" ] && { [ -e "$tasktmp" ] || [ -L "$tasktmp" ]; } || return 0
  if abs=$(fm_resource_validate_task_tmp "$id" "$tasktmp" "$owner" "$home" "$root" "$expected_tag"); then
    rm -rf -- "$abs"
    return $?
  else
    rc=$?
    return "$rc"
  fi
}

# fm_resource_remove_legacy_task_tmp: remove the pre-manifest GOTMPDIR root
# created by the supported lifecycle before owner markers existed. This narrow
# compatibility path is intentionally separate from fm_resource_remove_task_tmp:
# generic cleanup must continue to preserve every untagged directory. A legacy
# root is provable only when it is the canonical /tmp/fm-<id> directory recorded
# for this task, has a real gotmp child, and has no modern owner marker.
fm_resource_remove_legacy_task_tmp() {  # <id> <tasktmp> <owner> <home> <root>
  local id=$1 tasktmp=$2 owner=$3 home=$4 root=$5 abs rc tmp_parent expected owner_expected
  [ -n "$tasktmp" ] && { [ -e "$tasktmp" ] || [ -L "$tasktmp" ]; } || return 0
  if abs=$(fm_resource_validate_task_tmp "$id" "$tasktmp" "$owner" "$home" "$root" 2>/dev/null); then
    echo "resource: preserving task temp root with a modern owner marker but no manifest $tasktmp" >&2
    return 2
  else
    rc=$?
  fi
  [ "$rc" -eq 2 ] || {
    echo "resource: preserving unproven legacy task temp root $tasktmp" >&2
    return "$rc"
  }
  abs=$(cd "$tasktmp" && pwd -P) || return 1
  [ ! -e "$tasktmp/$FM_RESOURCE_OWNER_MARKER" ] && [ ! -L "$tasktmp/$FM_RESOURCE_OWNER_MARKER" ] || {
    echo "resource: preserving task temp root with an owner marker but no manifest $tasktmp" >&2
    return 2
  }
  tmp_parent=$(fm_resource_real_dir /tmp) || return 1
  expected="$tmp_parent/fm-$id"
  [ "$abs" = "$expected" ] || {
    echo "resource: preserving unproven legacy task temp root $tasktmp" >&2
    return 2
  }
  [ -d "$abs/gotmp" ] && [ ! -L "$abs/gotmp" ] || {
    echo "resource: preserving unproven legacy task temp root $tasktmp" >&2
    return 2
  }
  owner_expected=$(fm_resource_owner_for "$home" "$root" "$id") || return 1
  [ "$owner" = "$owner_expected" ] || {
    echo "resource: preserving legacy task temp root with mismatched owner $tasktmp" >&2
    return 2
  }
  rm -rf -- "$abs"
}

fm_resource_docker_ids_for_label() {  # <resource-kind> <label-key> <label-value>
  local kind=$1 key=$2 value=$3
  case "$kind" in
    container) docker ps -aq --filter "label=$key=$value" 2>/dev/null ;;
    service) docker service ls -q --filter "label=$key=$value" 2>/dev/null ;;
    volume) docker volume ls -q --filter "label=$key=$value" 2>/dev/null ;;
    network) docker network ls -q --filter "label=$key=$value" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

fm_resource_docker_inspect_labels() {  # <resource-kind> <resource-id>
  local kind=$1 id=$2 label_path template
  case "$kind" in
    container) label_path=Config.Labels ;;
    service) label_path=Spec.Labels ;;
    volume|network) label_path=Labels ;;
    *) return 1 ;;
  esac
  # A non-whitespace separator preserves empty leading label fields during
  # Bash parsing, so Compose resources with no firstmate labels remain provable.
  printf -v template '{{ index .%s "%s" }}|{{ index .%s "%s" }}|{{ index .%s "%s" }}|{{ index .%s "%s" }}|{{ index .%s "%s" }}|{{ index .%s "%s" }}' \
    "$label_path" "$FM_RESOURCE_OWNER_LABEL" \
    "$label_path" "$FM_RESOURCE_TASK_LABEL" \
    "$label_path" "$FM_RESOURCE_HOME_LABEL" \
    "$label_path" "$FM_RESOURCE_BACKEND_LABEL" \
    "$label_path" "$FM_RESOURCE_ENDPOINT_LABEL" \
    "$label_path" com.docker.compose.project
  case "$kind" in
    service) docker service inspect --format "$template" "$id" 2>/dev/null ;;
    *) docker inspect --format "$template" "$id" 2>/dev/null ;;
  esac
}

fm_resource_docker_exists() {  # <resource-kind> <resource-id>
  case "$1" in
    service) docker service inspect "$2" >/dev/null 2>&1 ;;
    container|volume|network) docker inspect "$2" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

fm_resource_docker_labels_match() {  # <owner> <task> <compose> <home-tag> <backend> <endpoint> <labels>
  local owner=$1 task=$2 compose=$3 expected_home=$4 expected_backend=$5 expected_endpoint=$6 labels=$7
  local actual_owner actual_task actual_home actual_backend actual_endpoint actual_project
  IFS='|' read -r actual_owner actual_task actual_home actual_backend actual_endpoint actual_project <<EOF
$labels
EOF
  [ "$actual_owner" != '<no value>' ] || actual_owner=
  [ "$actual_task" != '<no value>' ] || actual_task=
  [ "$actual_home" != '<no value>' ] || actual_home=
  [ "$actual_backend" != '<no value>' ] || actual_backend=
  [ "$actual_endpoint" != '<no value>' ] || actual_endpoint=
  [ "$actual_project" != '<no value>' ] || actual_project=

  if [ "$actual_owner" = "$owner" ]; then
    [ "$actual_task" = "$task" ] || return 1
    [ -z "$expected_home" ] && [ -z "$actual_home" ] || [ "$actual_home" = "$expected_home" ] || return 1
    [ -z "$expected_backend" ] && [ -z "$actual_backend" ] || [ "$actual_backend" = "$expected_backend" ] || return 1
    [ -z "$expected_endpoint" ] && [ -z "$actual_endpoint" ] || [ "$actual_endpoint" = "$expected_endpoint" ] || return 1
    return 0
  fi

  # Compose resources do not inherit the task wrapper's labels, but the exact
  # generated project name is their ownership marker. Any firstmate label that
  # is present must still be absent rather than conflicting with that proof.
  [ -n "$compose" ] && [ "$actual_project" = "$compose" ] || return 1
  [ -z "$actual_owner" ] && [ -z "$actual_task" ] && [ -z "$actual_home" ] \
    && [ -z "$actual_backend" ] && [ -z "$actual_endpoint" ]
}

_fm_resource_docker_cleanup_kinds() {  # <owner> <task> <compose> <require> <home-tag> <backend> <endpoint> <service-used> <kinds...>
  local owner=$1 task=$2 compose=$3
  local require_daemon=0 expected_home= expected_backend= expected_endpoint= service_used=0
  [ "$#" -ge 4 ] && require_daemon=$4
  [ "$#" -ge 5 ] && expected_home=$5
  [ "$#" -ge 6 ] && expected_backend=$6
  [ "$#" -ge 7 ] && expected_endpoint=$7
  [ "$#" -ge 8 ] && service_used=$8
  shift 8
  local kind owner_ids compose_ids ids cid labels
  command -v docker >/dev/null 2>&1 || {
    [ "$require_daemon" = 1 ] && {
      echo "error: Docker is required to clean resources tagged for $owner" >&2
      return 1
    }
    return 0
  }
  for kind in "$@"; do
    [ "$kind" = service ] && [ "$service_used" != 1 ] && continue
    owner_ids=$(fm_resource_docker_ids_for_label "$kind" "$FM_RESOURCE_OWNER_LABEL" "$owner") || {
      if [ "$require_daemon" = 1 ]; then
        echo "error: Docker $kind owner-label query failed for $owner; preserving resources" >&2
        return 1
      fi
      continue
    }
    compose_ids=
    if [ -n "$compose" ]; then
      compose_ids=$(fm_resource_docker_ids_for_label "$kind" com.docker.compose.project "$compose") || {
        if [ "$require_daemon" = 1 ]; then
          echo "error: Docker $kind Compose-label query failed for $compose; preserving resources" >&2
          return 1
        fi
        continue
      }
    fi
    ids=$(printf '%s\n%s\n' "$owner_ids" "$compose_ids" | awk 'NF && !seen[$0]++')
    while IFS= read -r cid; do
      [ -n "$cid" ] || continue
      case "$cid" in
        ''|*[!A-Za-z0-9_.-]*)
          echo "REFUSED: Docker returned an unsafe $kind id for $owner: $cid" >&2
          return 1
          ;;
      esac
      labels=$(fm_resource_docker_inspect_labels "$kind" "$cid") || {
        echo "error: cannot inspect Docker $kind $cid; preserving it" >&2
        return 1
      }
      fm_resource_docker_labels_match "$owner" "$task" "$compose" "$expected_home" "$expected_backend" "$expected_endpoint" "$labels" || {
        echo "REFUSED: Docker $kind $cid has no exact firstmate ownership proof; preserving it" >&2
        return 1
      }
      case "$kind" in
        container) docker rm -f "$cid" >/dev/null 2>&1 ;;
        service) docker service rm "$cid" >/dev/null 2>&1 ;;
        volume) docker volume rm "$cid" >/dev/null 2>&1 ;;
        network) docker network rm "$cid" >/dev/null 2>&1 ;;
      esac || {
        echo "error: failed to remove Docker $kind $cid; preserving it" >&2
        return 1
      }
      if fm_resource_docker_exists "$kind" "$cid"; then
        echo "error: Docker $kind $cid still exists after removal; preserving metadata" >&2
        return 1
      fi
      echo "resource: removed Docker $kind $cid for $owner"
    done <<EOF
$ids
EOF
  done
}

fm_resource_docker_cleanup() {  # <owner> <task> <compose-project> <require-daemon> [<home-tag> <backend> <endpoint> <service-used>]
  local require_daemon=0 home_tag= backend= endpoint= service_used=0
  [ "$#" -ge 4 ] && require_daemon=$4
  [ "$#" -ge 5 ] && home_tag=$5
  [ "$#" -ge 6 ] && backend=$6
  [ "$#" -ge 7 ] && endpoint=$7
  [ "$#" -ge 8 ] && service_used=$8
  _fm_resource_docker_cleanup_kinds "$1" "$2" "$3" "$require_daemon" "$home_tag" "$backend" "$endpoint" "$service_used" container service network volume
}

fm_resource_docker_cleanup_noncontainers() {  # <owner> <task> <compose-project> <require-daemon> [<home-tag> <backend> <endpoint> <service-used>]
  local require_daemon=0 home_tag= backend= endpoint= service_used=0
  [ "$#" -ge 4 ] && require_daemon=$4
  [ "$#" -ge 5 ] && home_tag=$5
  [ "$#" -ge 6 ] && backend=$6
  [ "$#" -ge 7 ] && endpoint=$7
  [ "$#" -ge 8 ] && service_used=$8
  _fm_resource_docker_cleanup_kinds "$1" "$2" "$3" "$require_daemon" "$home_tag" "$backend" "$endpoint" "$service_used" service network volume
}

fm_resource_chrome_cleanup() {  # <owner> <task> <home> <root> <home-tag> <tasktmp> <session> <profile> <owned> <used> [<chrome-real>]
  local owner=$1 task=$2 home=$3 root=$4 expected_tag=$5 tasktmp=$6 session=$7 profile=$8 owned=${9:-0} used=${10:-0}
  local chrome_real=${11:-} marker marker_version marker_owner marker_task marker_home marker_root marker_tag marker_resource marker_session chrome
  local tasktmp_abs profile_abs
  [ "$owned" = 1 ] || return 0
  [ -n "$tasktmp" ] && [ -n "$profile" ] || {
    echo "REFUSED: owned Chrome resource has no task-scoped profile path" >&2
    return 1
  }
  [ "$profile" = "$tasktmp/chrome-profile" ] || {
    echo "REFUSED: Chrome profile path is not the task's exact profile: $profile" >&2
    return 1
  }
  [ -e "$profile" ] || [ -L "$profile" ] || return 0
  [ -d "$profile" ] && [ ! -L "$profile" ] || {
    echo "REFUSED: Chrome profile is not a real directory: $profile" >&2
    return 1
  }
  tasktmp_abs=$(fm_resource_real_dir "$tasktmp") || return 1
  profile_abs=$(fm_resource_real_dir "$profile") || return 1
  case "$profile_abs" in
    "$tasktmp_abs/chrome-profile") ;;
    *) echo "REFUSED: Chrome profile resolves outside the task temp root: $profile" >&2; return 1 ;;
  esac
  marker="$profile/$FM_RESOURCE_OWNER_MARKER"
  if [ -L "$marker" ]; then
    echo "REFUSED: Chrome profile owner marker is not a regular file: $marker" >&2
    return 1
  fi
  [ -f "$marker" ] || {
    echo "REFUSED: Chrome profile $profile has no matching firstmate owner marker" >&2
    return 1
  }
  marker_version=$(fm_resource_marker_get "$marker" version)
  marker_owner=$(fm_resource_marker_get "$marker" owner)
  marker_task=$(fm_resource_marker_get "$marker" task)
  marker_home=$(fm_resource_marker_get "$marker" home)
  marker_root=$(fm_resource_marker_get "$marker" root)
  marker_tag=$(fm_resource_marker_get "$marker" home_tag)
  marker_resource=$(fm_resource_marker_get "$marker" resource)
  marker_session=$(fm_resource_marker_get "$marker" session)
  [ "$marker_version" = 1 ] && [ "$marker_owner" = "$owner" ] && [ "$marker_task" = "$task" ] \
    && [ "$marker_home" = "$home" ] && [ "$marker_root" = "$root" ] \
    && [ "$marker_tag" = "$expected_tag" ] && [ "$marker_resource" = chrome ] \
    && [ "$marker_session" = "$session" ] || {
    echo "REFUSED: Chrome profile $profile has no matching firstmate owner marker" >&2
    return 1
  }
  if [ "$used" = 1 ]; then
    chrome=$chrome_real
    [ -n "$chrome" ] || chrome=$(type -P chrome-devtools-axi 2>/dev/null || true)
    [ -n "$chrome" ] && [ -x "$chrome" ] || {
      echo "error: chrome-devtools-axi is required to close browser session $session" >&2
      return 1
    }
    env CHROME_DEVTOOLS_AXI_SESSION="$session" CHROME_DEVTOOLS_AXI_USER_DATA_DIR="$profile_abs" "$chrome" stop >/dev/null 2>&1 || {
      echo "error: could not close owned Chrome session $session; preserving profile" >&2
      return 1
    }
  fi
  rm -rf -- "$profile_abs"
  [ ! -e "$profile_abs" ] || {
    echo "error: owned Chrome profile still exists after removal: $profile_abs" >&2
    return 1
  }
  echo "resource: removed Chrome profile for $owner"
  return 0
}

fm_resource_cleanup_task() {  # <id> <home> <root> <state> <tasktmp> [<manifest>] [<allow-legacy-tasktmp>]
  local id=$1 home=$2 root=$3 state=$4 tasktmp=${5:-} manifest=${6:-} allow_legacy_tasktmp=${7:-0}
  local owner manifest_tmp manifest_home manifest_root backend= endpoint= compose= chrome_session= chrome_label= profile= chrome_owned= chrome_real= docker_used chrome_used service_used
  local resource_home resource_root resource_home_abs resource_root_abs home_tag state_abs expected_manifest manifest_dir manifest_base manifest_present=0
  state_abs=$(fm_resource_real_dir "$state") || return 1
  expected_manifest="$state_abs/$id$FM_RESOURCE_MANIFEST_SUFFIX"
  if [ -n "$manifest" ]; then
    manifest_base=$(basename "$manifest")
    manifest_dir=$(fm_resource_real_dir "$(dirname "$manifest")") || return 1
    manifest="$manifest_dir/$manifest_base"
    [ "$manifest" = "$expected_manifest" ] || {
      echo "REFUSED: resource manifest path is outside the task state directory" >&2
      return 1
    }
  else
    manifest=$expected_manifest
  fi
  if [ -L "$manifest" ]; then
    echo "REFUSED: resource manifest is a symbolic link: $manifest" >&2
    return 1
  fi
  if [ -f "$manifest" ]; then
    manifest_present=1
    fm_resource_validate_manifest "$id" "$state" "$manifest" || {
      echo "REFUSED: resource manifest $manifest is incomplete or mismatched" >&2
      return 1
    }
    owner=$(fm_resource_manifest_get "$manifest" owner)
    manifest_home=$(fm_resource_manifest_get "$manifest" home)
    manifest_root=$(fm_resource_manifest_get "$manifest" root)
    resource_home=${manifest_home:-$home}
    resource_root=${manifest_root:-$root}
    resource_home_abs=$(fm_resource_real_dir "$resource_home") || return 1
    resource_root_abs=$(fm_resource_real_dir "$resource_root") || return 1
    resource_home=$resource_home_abs
    resource_root=$resource_root_abs
    home_tag=$(fm_resource_manifest_get "$manifest" home_tag)
    manifest_tmp=$(fm_resource_manifest_get "$manifest" tasktmp)
    if [ -n "$tasktmp" ] && [ -n "$manifest_tmp" ] && [ "$tasktmp" != "$manifest_tmp" ]; then
      echo "REFUSED: task temp root differs between metadata and resource manifest" >&2
      return 1
    fi
    [ -n "$tasktmp" ] || tasktmp=$manifest_tmp
    backend=$(fm_resource_manifest_get "$manifest" backend)
    endpoint=$(fm_resource_manifest_get "$manifest" endpoint)
    compose=$(fm_resource_manifest_get "$manifest" docker_project)
    chrome_session=$(fm_resource_manifest_get "$manifest" chrome_session)
    chrome_label=$(fm_resource_manifest_get "$manifest" chrome_label)
    profile=$(fm_resource_manifest_get "$manifest" chrome_profile)
    chrome_owned=$(fm_resource_manifest_get "$manifest" chrome_owned)
    chrome_real=$(fm_resource_manifest_get "$manifest" chrome_real)
    docker_used=0
    chrome_used=0
    service_used=0
    [ -e "$manifest.docker-used" ] && docker_used=1
    [ -e "$manifest.chrome-used" ] && chrome_used=1
    [ -e "$manifest.docker-service-used" ] && service_used=1
    [ -z "$chrome_label" ] || [ "$chrome_label" = "$chrome_session" ] || {
      echo "REFUSED: resource manifest $manifest has a mismatched Chrome label" >&2
      return 1
    }
  else
    resource_home_abs=$(fm_resource_real_dir "$home") || return 1
    resource_root_abs=$(fm_resource_real_dir "$root") || return 1
    resource_home=$resource_home_abs
    resource_root=$resource_root_abs
    home_tag=$(fm_resource_home_tag_for "$resource_home" "$resource_root") || return 1
    owner=$(fm_resource_owner_for "$resource_home" "$resource_root" "$id") || return 1
    docker_used=0
    chrome_used=0
    service_used=0
    chrome_owned=0
    chrome_session=
    chrome_label=
    chrome_real=
    profile=
    compose=$(fm_resource_compose_project_for "$resource_home" "$resource_root" "$id") || return 1
  fi
  fm_resource_docker_cleanup "$owner" "$id" "$compose" "$docker_used" "$home_tag" "$backend" "$endpoint" "$service_used" || return 1
  if [ -n "$profile" ] && [ -n "$chrome_session" ]; then
    fm_resource_chrome_cleanup "$owner" "$id" "$resource_home" "$resource_root" "$home_tag" "$tasktmp" "$chrome_session" "$profile" "$chrome_owned" "$chrome_used" "$chrome_real" || return 1
  fi
  if [ "$allow_legacy_tasktmp" = 1 ] && [ "$manifest_present" = 0 ] \
    && [ -n "$tasktmp" ] && [ ! -e "$tasktmp/$FM_RESOURCE_OWNER_MARKER" ] && [ ! -L "$tasktmp/$FM_RESOURCE_OWNER_MARKER" ]; then
    fm_resource_remove_legacy_task_tmp "$id" "$tasktmp" "$owner" "$resource_home" "$resource_root" || return 1
  else
    fm_resource_remove_task_tmp "$id" "$tasktmp" "$owner" "$resource_home" "$resource_root" "$home_tag" || return 1
  fi
  rm -f "$manifest" "$manifest.docker-used" "$manifest.chrome-used" "$manifest.docker-service-used"
}

fm_resource_endpoint_cleanup() {  # <id> <home> <root> <meta> <manifest>
  local id=$1 home=$2 root=$3 meta=$4 manifest=$5 backend target tab_id expected_label manifest_backend manifest_target
  [ -L "$meta" ] && return 1
  if [ -f "$meta" ]; then
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    tab_id=$(fm_meta_get "$meta" zellij_tab_id)
    manifest_backend=$(fm_resource_manifest_get "$manifest" backend)
    manifest_target=$(fm_resource_manifest_get "$manifest" endpoint)
    [ -n "$manifest_backend" ] && [ "$manifest_backend" = "$backend" ] || return 1
    [ -n "$manifest_target" ] && [ "$manifest_target" = "$target" ] || return 1
  else
    backend=$(fm_resource_manifest_get "$manifest" backend)
    target=$(fm_resource_manifest_get "$manifest" endpoint)
    tab_id=
  fi
  expected_label="fm-$id"
  [ -n "$backend" ] && [ -n "$target" ] || return 1
  if [ ! -f "$meta" ]; then
    if ( FM_HOME=$home FM_ROOT=$root fm_backend_target_exists "$backend" "$target" "$expected_label" >/dev/null 2>&1 ); then
      echo "resource: preserving orphan endpoint $target because its ownership record is incomplete" >&2
      return 1
    fi
    return 0
  fi
  if ! ( FM_HOME=$home FM_ROOT=$root fm_backend_target_exists "$backend" "$target" "$expected_label" >/dev/null 2>&1 ); then
    return 0
  fi
  if ( FM_HOME=$home FM_ROOT=$root fm_backend_kill "$backend" "$target" "$tab_id" "$expected_label" >/dev/null 2>&1 ); then
    return 0
  fi
  if ! ( FM_HOME=$home FM_ROOT=$root fm_backend_target_exists "$backend" "$target" "$expected_label" >/dev/null 2>&1 ); then
    return 0
  fi
  echo "error: could not remove orphan task endpoint $target; preserving resource manifest" >&2
  return 1
}

fm_resource_owner_is_dead() {  # <meta> <manifest>
  local meta=$1 manifest=$2 backend target alive expected_label
  if [ -f "$meta" ]; then
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    expected_label="fm-$(basename "$meta" .meta)"
  else
    backend=$(fm_resource_manifest_get "$manifest" backend)
    target=$(fm_resource_manifest_get "$manifest" endpoint)
    expected_label="fm-$(fm_resource_manifest_get "$manifest" task)"
  fi
  [ -n "$backend" ] && [ -n "$target" ] || return 1
  if fm_backend_target_exists "$backend" "$target" "$expected_label" >/dev/null 2>&1; then
    alive=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null || true)
    case "$alive" in
      dead) return 0 ;;
      alive|unknown) return 1 ;;
    esac
  fi
  [ "$backend" = tmux ] && {
    local session sessions
    session=${target%%:*}
    if sessions=$(tmux list-sessions 2>/dev/null); then
      if printf '%s\n' "$sessions" | grep -Fq "${session}:"; then
        return 0
      fi
      return 0
    fi
    sessions=$(tmux list-sessions 2>&1 || true)
    case "$sessions" in
      *"no server running"*|*"failed to connect"*) return 0 ;;
    esac
    if tmux has-session -t "$session" >/dev/null 2>&1; then
      return 0
    fi
  }
  return 1
}
