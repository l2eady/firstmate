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
  local home_abs root_abs state_abs owner tag compose chrome_session profile marker manifest tmp
  local real_docker real_chrome existing_owner existing_task umask_save
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

  if [ -e "$tasktmp" ]; then
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
  local child
  for child in "$tasktmp/gotmp" "$tasktmp/bin" "$profile"; do
    if [ -e "$child" ] && { [ ! -d "$child" ] || [ -L "$child" ]; }; then
      echo "REFUSED: task resource path is not a real directory: $child" >&2
      return 1
    fi
  done
  mkdir -p "$tasktmp/gotmp" "$tasktmp/bin" "$profile" || return 1

  if [ -e "$marker" ] && { [ ! -f "$marker" ] || [ -L "$marker" ]; }; then
    echo "REFUSED: task temp owner marker is not a regular file: $marker" >&2
    return 1
  fi
  {
    echo "version=1"
    echo "owner=$owner"
    echo "task=$id"
    echo "home=$home_abs"
    echo "home_tag=$tag"
  } > "$marker" || return 1
  {
    echo "version=1"
    echo "owner=$owner"
    echo "task=$id"
    echo "home=$home_abs"
    echo "home_tag=$tag"
  } > "$profile/$FM_RESOURCE_OWNER_MARKER" || return 1

  real_docker=$(type -P docker 2>/dev/null || true)
  real_chrome=$(type -P chrome-devtools-axi 2>/dev/null || true)
  rm -f "$tasktmp/bin/docker" "$tasktmp/bin/chrome-devtools-axi"
  if [ -n "$real_docker" ] && [ -x "$real_docker" ] && [ "$real_docker" != "$tasktmp/bin/docker" ]; then
    ln -s "$_FM_RESOURCE_LIB_DIR/fm-resource-docker.sh" "$tasktmp/bin/docker"
  else
    real_docker=
  fi
  if [ "$browser_owned" = 1 ] && [ -n "$real_chrome" ] && [ -x "$real_chrome" ] && [ "$real_chrome" != "$tasktmp/bin/chrome-devtools-axi" ]; then
    ln -s "$_FM_RESOURCE_LIB_DIR/fm-resource-chrome.sh" "$tasktmp/bin/chrome-devtools-axi"
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
    echo "chrome_profile=$profile"
    echo "chrome_owned=$browser_owned"
    echo "chrome_real=$real_chrome"
  } > "$tmp"
  umask "$umask_save"
  mv -f "$tmp" "$manifest" || return 1
  printf '%s\n' "$manifest"
}

fm_resource_task_env_line() {  # <manifest>
  local manifest=$1 task owner home tag state tasktmp backend endpoint compose chrome_session profile docker_real chrome_real chrome_owned
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
  profile=$(fm_resource_manifest_get "$manifest" chrome_profile)
  docker_real=$(fm_resource_manifest_get "$manifest" docker_real)
  chrome_real=$(fm_resource_manifest_get "$manifest" chrome_real)
  chrome_owned=$(fm_resource_manifest_get "$manifest" chrome_owned)
  [ -n "$task" ] && [ -n "$owner" ] && [ -n "$tasktmp" ] || return 1
  printf 'export FM_TASK_ID=%s FM_TASK_RESOURCE_OWNER=%s FM_TASK_RESOURCE_HOME=%s FM_TASK_RESOURCE_HOME_TAG=%s FM_TASK_RESOURCE_MANIFEST=%s FM_TASK_RESOURCE_STATE=%s FM_TASK_RESOURCE_BACKEND=%s FM_TASK_RESOURCE_ENDPOINT=%s FM_RESOURCE_DOCKER_PROJECT=%s FM_RESOURCE_CHROME_SESSION=%s FM_RESOURCE_CHROME_PROFILE=%s FM_RESOURCE_CHROME_OWNED=%s\n' \
    "$(fm_resource_shell_quote "$task")" "$(fm_resource_shell_quote "$owner")" "$(fm_resource_shell_quote "$home")" "$(fm_resource_shell_quote "$tag")" "$(fm_resource_shell_quote "$manifest")" "$(fm_resource_shell_quote "$state")" "$(fm_resource_shell_quote "$backend")" "$(fm_resource_shell_quote "$endpoint")" "$(fm_resource_shell_quote "$compose")" "$(fm_resource_shell_quote "$chrome_session")" "$(fm_resource_shell_quote "$profile")" "$(fm_resource_shell_quote "$chrome_owned")"
  printf 'export PATH=%s:$PATH\n' "$(fm_resource_shell_quote "$(dirname "$tasktmp")/$(basename "$tasktmp")/bin")"
  printf 'export COMPOSE_PROJECT_NAME=%s FM_RESOURCE_REAL_DOCKER=%s FM_RESOURCE_REAL_CHROME=%s\n' \
    "$(fm_resource_shell_quote "$compose")" "$(fm_resource_shell_quote "$docker_real")" "$(fm_resource_shell_quote "$chrome_real")"
  if [ "$chrome_owned" = 1 ]; then
    printf 'export CHROME_DEVTOOLS_AXI_SESSION=%s CHROME_DEVTOOLS_AXI_USER_DATA_DIR=%s\n' "$(fm_resource_shell_quote "$chrome_session")" "$(fm_resource_shell_quote "$profile")"
  fi
}

fm_resource_validate_task_tmp() {  # <id> <tasktmp> <owner>
  local id=$1 tasktmp=$2 owner=$3 marker marker_owner marker_task abs base parent base_abs
  [ -n "$tasktmp" ] || return 0
  [ -e "$tasktmp" ] || return 0
  [ -d "$tasktmp" ] && [ ! -L "$tasktmp" ] || {
    echo "REFUSED: task temp root is not a real directory: $tasktmp" >&2
    return 1
  }
  abs=$(cd "$tasktmp" && pwd -P) || return 1
  base=$(basename "$abs")
  parent=$(dirname "$abs")
  base_abs=$(cd "$parent" && pwd -P) || return 1
  [ "$base" = "fm-$id" ] || {
    echo "REFUSED: task temp root $tasktmp is not named fm-$id" >&2
    return 1
  }
  case "$base_abs" in
    /|"$abs")
      echo "REFUSED: task temp root parent is unsafe: $tasktmp" >&2
      return 1
      ;;
  esac
  marker="$abs/$FM_RESOURCE_OWNER_MARKER"
  if [ -e "$marker" ] && { [ ! -f "$marker" ] || [ -L "$marker" ]; }; then
    echo "REFUSED: task temp owner marker is not a regular file: $marker" >&2
    return 1
  fi
  marker_owner=$(fm_resource_marker_get "$marker" owner)
  marker_task=$(fm_resource_marker_get "$marker" task)
  if [ "$marker_owner" != "$owner" ] || [ "$marker_task" != "$id" ]; then
    echo "resource: preserving untagged task temp root $tasktmp" >&2
    return 2
  fi
  printf '%s\n' "$abs"
}

fm_resource_remove_task_tmp() {  # <id> <tasktmp> <owner>
  local id=$1 tasktmp=$2 owner=$3 abs rc
  [ -n "$tasktmp" ] && [ -e "$tasktmp" ] || return 0
  if abs=$(fm_resource_validate_task_tmp "$id" "$tasktmp" "$owner"); then
    rm -rf -- "$abs"
    return $?
  else
    rc=$?
    return "$rc"
  fi
}

fm_resource_docker_ids_for_label() {  # <resource-kind> <label-key> <label-value>
  local kind=$1 key=$2 value=$3
  case "$kind" in
    container) docker ps -aq --filter "label=$key=$value" 2>/dev/null ;;
    volume) docker volume ls -q --filter "label=$key=$value" 2>/dev/null ;;
    network) docker network ls -q --filter "label=$key=$value" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

fm_resource_docker_cleanup() {  # <owner> <task> <compose-project> <require-daemon>
  local owner=$1 task=$2 compose=$3 require_daemon=${4:-0}
  local ids cid labels actual_owner actual_task actual_home actual_backend actual_endpoint actual_project
  command -v docker >/dev/null 2>&1 || {
    [ "$require_daemon" = 1 ] && {
      echo "error: Docker is required to clean resources tagged for $owner" >&2
      return 1
    }
    return 0
  }
  ids=$(fm_resource_docker_ids_for_label container "$FM_RESOURCE_OWNER_LABEL" "$owner") || {
    [ "$require_daemon" = 1 ] && echo "error: Docker label query failed for $owner" >&2
    [ "$require_daemon" = 1 ] && return 1
    return 0
  }
  if [ -n "$compose" ]; then
    while IFS= read -r cid; do
      [ -n "$cid" ] || continue
      case " $ids " in *" $cid "*) ;; *) ids="$ids${ids:+$'\n'}$cid" ;; esac
    done < <(fm_resource_docker_ids_for_label container com.docker.compose.project "$compose")
  fi
  for cid in $ids; do
    case "$cid" in
      ''|*[!A-Za-z0-9_.-]*)
        echo "REFUSED: Docker returned an unsafe resource id for $owner: $cid" >&2
        return 1
        ;;
    esac
    labels=$(docker inspect --format '{{ index .Config.Labels "com.firstmate.owner" }}	{{ index .Config.Labels "com.firstmate.task" }}	{{ index .Config.Labels "com.firstmate.home" }}	{{ index .Config.Labels "com.firstmate.backend" }}	{{ index .Config.Labels "com.firstmate.endpoint" }}	{{ index .Config.Labels "com.docker.compose.project" }}' "$cid" 2>/dev/null) || {
      echo "error: cannot inspect Docker resource $cid; preserving it" >&2
      return 1
    }
    IFS=$'\t' read -r actual_owner actual_task actual_home actual_backend actual_endpoint actual_project <<EOF
$labels
EOF
    [ "$actual_owner" != '<no value>' ] || actual_owner=
    [ "$actual_task" != '<no value>' ] || actual_task=
    [ "$actual_home" != '<no value>' ] || actual_home=
    [ "$actual_backend" != '<no value>' ] || actual_backend=
    [ "$actual_endpoint" != '<no value>' ] || actual_endpoint=
    [ "$actual_project" != '<no value>' ] || actual_project=
    if [ "$actual_owner" != "$owner" ] && [ "$actual_project" != "$compose" ]; then
      echo "REFUSED: Docker resource $cid matched an unsafe label query; preserving it" >&2
      return 1
    fi
    [ -z "$actual_task" ] || [ "$actual_task" = "$task" ] || {
      echo "REFUSED: Docker resource $cid has a mismatched task label; preserving it" >&2
      return 1
    }
    docker rm -f "$cid" >/dev/null 2>&1 || {
      echo "error: failed to remove Docker resource $cid; preserving it" >&2
      return 1
    }
    if docker inspect "$cid" >/dev/null 2>&1; then
      echo "error: Docker resource $cid still exists after removal; preserving metadata" >&2
      return 1
    fi
    echo "resource: removed Docker resource $cid for $owner"
  done
}

fm_resource_docker_cleanup_noncontainers() {  # <owner> <task> <compose-project> <require-daemon>
  local owner=$1 task=$2 compose=$3 require_daemon=${4:-0}
  local kind ids cid labels actual_owner actual_task actual_project
  command -v docker >/dev/null 2>&1 || {
    [ "$require_daemon" = 1 ] && {
      echo "error: Docker is required to clean resources tagged for $owner" >&2
      return 1
    }
    return 0
  }
  for kind in volume network; do
    ids=$(fm_resource_docker_ids_for_label "$kind" "$FM_RESOURCE_OWNER_LABEL" "$owner") || {
      [ "$require_daemon" = 1 ] && echo "error: Docker $kind label query failed for $owner" >&2
      [ "$require_daemon" = 1 ] && return 1
      continue
    }
    if [ -n "$compose" ]; then
      while IFS= read -r cid; do
        [ -n "$cid" ] || continue
        case " $ids " in *" $cid "*) ;; *) ids="$ids${ids:+$'\n'}$cid" ;; esac
      done < <(fm_resource_docker_ids_for_label "$kind" com.docker.compose.project "$compose")
    fi
    for cid in $ids; do
      case "$cid" in
        ''|*[!A-Za-z0-9_.-]*)
          echo "REFUSED: Docker returned an unsafe $kind id for $owner: $cid" >&2
          return 1
          ;;
      esac
      labels=$(docker inspect --format '{{ index .Config.Labels "com.firstmate.owner" }}	{{ index .Config.Labels "com.firstmate.task" }}	{{ index .Config.Labels "com.docker.compose.project" }}' "$cid" 2>/dev/null) || {
        echo "error: cannot inspect Docker $kind $cid; preserving it" >&2
        return 1
      }
      IFS=$'\t' read -r actual_owner actual_task actual_project <<EOF
$labels
EOF
      [ "$actual_owner" != '<no value>' ] || actual_owner=
      [ "$actual_task" != '<no value>' ] || actual_task=
      [ "$actual_project" != '<no value>' ] || actual_project=
      if [ "$actual_owner" != "$owner" ] && [ "$actual_project" != "$compose" ]; then
        echo "REFUSED: Docker $kind $cid matched an unsafe label query; preserving it" >&2
        return 1
      fi
      [ -z "$actual_task" ] || [ "$actual_task" = "$task" ] || {
        echo "REFUSED: Docker $kind $cid has a mismatched task label; preserving it" >&2
        return 1
      }
      case "$kind" in
        volume) docker volume rm "$cid" >/dev/null 2>&1 ;;
        network) docker network rm "$cid" >/dev/null 2>&1 ;;
      esac || {
        echo "error: failed to remove Docker $kind $cid; preserving it" >&2
        return 1
      }
      if docker inspect "$cid" >/dev/null 2>&1; then
        echo "error: Docker $kind $cid still exists after removal; preserving metadata" >&2
        return 1
      fi
      echo "resource: removed Docker $kind $cid for $owner"
    done
  done
}

fm_resource_chrome_cleanup() {  # <owner> <tasktmp> <session> <profile> <owned> <used>
  local owner=$1 tasktmp=$2 session=$3 profile=$4 owned=${5:-0} used=${6:-0}
  local marker marker_owner chrome
  [ "$owned" = 1 ] || return 0
  marker="$profile/$FM_RESOURCE_OWNER_MARKER"
  if [ -e "$marker" ] && { [ ! -f "$marker" ] || [ -L "$marker" ]; }; then
    echo "REFUSED: Chrome profile owner marker is not a regular file: $marker" >&2
    return 1
  fi
  marker_owner=$(fm_resource_marker_get "$marker" owner)
  [ "$marker_owner" = "$owner" ] || {
    [ -e "$profile" ] || return 0
    echo "REFUSED: Chrome profile $profile has no matching firstmate owner marker" >&2
    return 1
  }
  if [ "$used" = 1 ]; then
    chrome=$(type -P chrome-devtools-axi 2>/dev/null || true)
    [ -n "$chrome" ] || {
      echo "error: chrome-devtools-axi is required to close browser session $session" >&2
      return 1
    }
    env CHROME_DEVTOOLS_AXI_SESSION="$session" CHROME_DEVTOOLS_AXI_USER_DATA_DIR="$profile" "$chrome" stop >/dev/null 2>&1 || {
      echo "error: could not close owned Chrome session $session; preserving profile" >&2
      return 1
    }
  fi
  rm -rf -- "$profile"
  echo "resource: removed Chrome profile for $owner"
  return 0
}

fm_resource_cleanup_task() {  # <id> <home> <root> <state> <tasktmp> [<manifest>]
  local id=$1 home=$2 root=$3 state=$4 tasktmp=${5:-} manifest=${6:-}
  local expected_owner owner manifest_tmp manifest_home manifest_root backend endpoint compose chrome_session profile chrome_owned docker_used chrome_used
  local resource_home resource_root state_abs expected_manifest manifest_dir manifest_base
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
  if [ -f "$manifest" ]; then
    owner=$(fm_resource_manifest_get "$manifest" owner)
    manifest_home=$(fm_resource_manifest_get "$manifest" home)
    manifest_root=$(fm_resource_manifest_get "$manifest" root)
    resource_home=${manifest_home:-$home}
    resource_root=${manifest_root:-$root}
    expected_owner=$(fm_resource_owner_for "$resource_home" "$resource_root" "$id") || return 1
    [ "$owner" = "$expected_owner" ] || {
      echo "REFUSED: resource manifest $manifest has an unproven owner" >&2
      return 1
    }
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
    profile=$(fm_resource_manifest_get "$manifest" chrome_profile)
    chrome_owned=$(fm_resource_manifest_get "$manifest" chrome_owned)
    docker_used=0
    chrome_used=0
    [ -e "$manifest.docker-used" ] && docker_used=1
    [ -e "$manifest.chrome-used" ] && chrome_used=1
  else
    expected_owner=$(fm_resource_owner_for "$home" "$root" "$id") || return 1
    owner=$expected_owner
    resource_home=$home
    resource_root=$root
    docker_used=0
    chrome_used=0
    chrome_owned=0
    chrome_session=
    profile=
    compose=$(fm_resource_compose_project_for "$home" "$root" "$id") || return 1
  fi
  fm_resource_docker_cleanup "$owner" "$id" "$compose" "$docker_used" || return 1
  fm_resource_docker_cleanup_noncontainers "$owner" "$id" "$compose" "$docker_used" || return 1
  if [ -n "$profile" ] && [ -n "$chrome_session" ]; then
    fm_resource_chrome_cleanup "$owner" "$tasktmp" "$chrome_session" "$profile" "$chrome_owned" "$chrome_used" || return 1
  fi
  fm_resource_remove_task_tmp "$id" "$tasktmp" "$owner" || return 1
  rm -f "$manifest" "$manifest.docker-used" "$manifest.chrome-used"
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
