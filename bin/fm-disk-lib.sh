#!/usr/bin/env bash
# Read-only home-filesystem free-space warning shared by bootstrap and watcher.
# FM_DISK_WARN_GB: positive integer decimal GB, default 50 (invalid values default).
# A failed or malformed df probe returns 2 and produces no warning.
# No resource retention or deletion is performed here.

fm_disk_warning() {  # <home>; prints a DISK line only below the threshold
  local home=$1 threshold=${FM_DISK_WARN_GB:-50} available
  case "$threshold" in
    *[!0-9]*|0*|'') threshold=50 ;;
    *) [ "${#threshold}" -le 9 ] || threshold=50 ;;
  esac
  available=$(LC_ALL=C df -Pk "$home" 2>/dev/null) || return 2
  available=$(printf '%s\n' "$available" | awk 'NR == 2 && $4 ~ /^[0-9]+$/ {print $4}')
  [ -n "$available" ] || return 2
  awk -v kb="$available" -v gb="$threshold" 'BEGIN {
    if (kb * 1024 < gb * 1000000000)
      printf "DISK: low free space on home filesystem: %.2f GB available (below %s GB); inspect disk usage and free space before starting more work\n", kb * 1024 / 1000000000, gb
  }'
}
