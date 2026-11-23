#!/usr/bin/env bash
# Invoke an owning project's orphan-only database cleanup with a bounded wait.
# The project's hook owns test database identification and all deletion rules.

fm_test_db_sweep() {  # <project-or-isolated-copy>
  local dir=$1 script timeout=${FM_TEST_DB_SWEEP_TIMEOUT:-45} out rc=0
  [ -n "$dir" ] && [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  script="$dir/scripts/e2e_db_cleanup.sh"
  [ -f "$script" ] && [ -x "$script" ] && [ ! -L "$script" ] && [ ! -L "$dir/scripts" ] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  case "$timeout" in ''|0*|*[!0-9]*) timeout=45 ;; esac
  out=$(cd "$dir" && fm_run_timed "$timeout" ./scripts/e2e_db_cleanup.sh --orphans </dev/null 2>&1) || rc=$?
  if fm_timed_out "$rc"; then
    printf 'TESTDB_SWEEP: %s timed out after %ss\n' "${dir##*/}" "$timeout"
  elif [ "$rc" = 0 ]; then
    printf '%s\n' "$out" | awk -v project="${dir##*/}" '/^removed /{ n++ } END { if (n) printf "TESTDB_SWEEP: %s collected %d orphan(s)\n", project, n }'
  fi
  return 0
}
