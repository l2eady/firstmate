#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-herdr-lab.sh
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  PATH="${FM_HERDR_TEST_REAL_PATH:-$PATH}" "${HERDR_LAB_HELPER:-$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh}" teardown "$1" || return 1
  if [ -n "${FM_HERDR_TEST_BRIDGE:-}" ]; then
    rm -f "$FM_HERDR_TEST_BRIDGE/herdr"
    rmdir "$FM_HERDR_TEST_BRIDGE"
  fi
}

# All real-test transport goes through the lab helper, including adapter status
# probes and subprocesses; the bridge can target only this one provisioned lab.
herdr_test_lab_provision() { # <session>
  export HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh}
  export FM_HERDR_TEST_SESSION=$1 FM_HERDR_TEST_REAL_PATH=$PATH
  "$HERDR_LAB_HELPER" provision "$1" || return 1
  FM_HERDR_TEST_BRIDGE=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-test-bridge.XXXXXX") || return 1
  export FM_HERDR_TEST_BRIDGE
  cat > "$FM_HERDR_TEST_BRIDGE/herdr" <<'BRIDGE'
#!/usr/bin/env bash
set -eu
args=()
session=$FM_HERDR_TEST_SESSION
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session)
      [ "$#" -ge 2 ] && [ "$2" = "$session" ] || exit 99
      shift 2 ;;
    --session=*) [ "${1#--session=}" = "$session" ] || exit 99; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
export PATH=$FM_HERDR_TEST_REAL_PATH
case "${args[0]:-} ${args[1]:-}" in
  'server ') exec "$HERDR_LAB_HELPER" provision "$session" ;;
  'session stop') [ "${args[2]:-}" = "$session" ] || exit 99; exec "$HERDR_LAB_HELPER" stop "$session" ;;
  *) exec "$HERDR_LAB_HELPER" run "$session" "${args[@]}" ;;
esac
BRIDGE
  chmod +x "$FM_HERDR_TEST_BRIDGE/herdr"
  export PATH="$FM_HERDR_TEST_BRIDGE:$PATH"
}
