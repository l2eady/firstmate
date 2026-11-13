#!/usr/bin/env bash
# Behavior tests for the worktree-tangle guards.
#
# Firstmate is a treehouse-pooled git repo of itself: linked worktrees and
# secondmate homes all sit at a detached HEAD on the default branch, while the
# PRIMARY checkout (FM_ROOT) is a normal checkout on a real branch. The "tangle"
# is a crewmate branching/committing in the primary instead of its own worktree,
# stranding the primary on a feature branch. Two guards cover it:
#   GUARD 1 (prevention) - the brief asserts isolation before its branch step, and
#            fm-spawn refuses to launch unless the resolved worktree is isolated.
#   GUARD 2 (detection)  - fm-guard and fm-bootstrap alarm when the primary is on
#            a feature branch, and stay silent on the default branch or detached.
# These cases pin: the shared lib's branch classification, the fm-guard banner,
# the fm-bootstrap problem line, the brief assertion ordering, and the fm-spawn
# abort - all hermetic over temp git repos and fakebins.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tangle-lib.sh
. "$ROOT/bin/fm-tangle-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tangle-guard)
fm_git_identity fmtest fmtest@example.invalid

# A fresh git repo on `main` with one commit. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# --- shared lib: branch classification --------------------------------------

# fm_primary_tangle_branch is the whole scoping decision: a NAMED non-default
# branch is the tangle; the default branch and detached HEAD are healthy.
test_lib_classification() {
  local repo n=0 label state branch expect out
  repo=$(make_repo "$TMP_ROOT/lib-repo")
  while IFS='|' read -r label state branch expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case "$state" in
      default)  git -C "$repo" checkout -q main ;;
      feature)  git -C "$repo" checkout -q -B "$branch" ;;
      detached) git -C "$repo" checkout -q main; git -C "$repo" checkout -q --detach ;;
    esac
    out=$(fm_primary_tangle_branch "$repo" || true)
    [ "$out" = "$expect" ] || fail "$label: expected tangle='$expect', got '$out'"
  done <<'ROWS'
on the default branch is healthy|default||
on a feature branch is the tangle|feature|fm/readme-restructure-d3|fm/readme-restructure-d3
detached HEAD on default is healthy (worktrees, secondmate homes)|detached||
ROWS
  # A non-git directory is not a tangle and must not error.
  out=$(fm_primary_tangle_branch "$TMP_ROOT" || true)
  [ -z "$out" ] || fail "non-git dir wrongly reported a tangle: '$out'"
  pass "fm_primary_tangle_branch: feature branch alarms; default/detached/non-git stay silent"
}

# --- GUARD 2a: fm-guard banner ----------------------------------------------

run_guard() {
  # Scope the guard to a temp repo as the primary checkout; state lives under it.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-guard.sh" 2>&1
}

test_guard_banner() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/guard-repo")

  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed while primary was on main"

  git -C "$repo" checkout -q --detach
  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed on a detached HEAD (legitimate worktree state)"

  git -C "$repo" checkout -q -B fm/tangle-aa1
  out=$(run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "guard did not alarm on a feature branch in the primary"
  assert_contains "$out" "fm/tangle-aa1" "guard banner did not name the offending branch"
  assert_contains "$out" "checkout main" "guard banner did not print the restore remediation"
  out=$(FM_GUARD_READ_ONLY=1 run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "read-only guard did not keep the tangle alarm"
  assert_contains "$out" "read-only session must leave restore work" "read-only guard did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "read-only guard printed a state-changing restore command"
  pass "fm-guard: bordered tangle banner fires only for a feature branch and suppresses repair commands in read-only mode"
}

# --- GUARD 2b: fm-bootstrap problem line ------------------------------------

run_bootstrap() {
  # No projects/ under the home keeps fleet sync inert; grep isolates the line.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_line() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/bootstrap-repo")

  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line while on main: $out"

  git -C "$repo" checkout -q --detach
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line on a detached HEAD: $out"

  git -C "$repo" checkout -q -B fm/tangle-bb2
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "bootstrap did not report the tangled branch"
  assert_contains "$out" "checkout main" "bootstrap TANGLE line lacked the restore remediation"
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "detect-only bootstrap did not report the tangled branch"
  assert_contains "$out" "read-only session must leave restore work" "detect-only bootstrap did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "detect-only bootstrap printed a state-changing restore command"
  pass "fm-bootstrap: TANGLE problem line fires only for a feature branch and suppresses repair commands in detect-only mode"
}

# --- GUARD 1a: brief isolation assertion ------------------------------------

# The generated ship brief must carry the isolation assertion AHEAD of the
# `git checkout -b` step, so the crewmate verifies its worktree before branching.
test_brief_assertion_precedes_branch() {
  local home brief iso br
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tangle-brief-cc3 alpha >/dev/null 2>&1
  brief="$home/data/tangle-brief-cc3/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "blocked: launched in primary checkout, not an isolated worktree" "$brief" \
    "brief is missing the isolation blocked-status contract"
  assert_grep "The path check is authoritative" "$brief" \
    "brief must make the path check authoritative"
  assert_grep "git branch --show-current" "$brief" \
    "brief must recognize a respawned worktree already on the task branch"
  assert_grep "git checkout fm/" "$brief" \
    "brief must resume an existing task branch without detaching another worktree"
  assert_no_grep "A reliable test that you are in a linked worktree" "$brief" \
    "brief must not present git-dir/common-dir as decisive"
  assert_no_grep "they are identical in the primary checkout" "$brief" \
    "brief must not claim the primary checkout has identical git dirs"
  iso=$(grep -n 'launched in primary checkout, not an isolated worktree' "$brief" | head -1 | cut -d: -f1)
  br=$(grep -n 'git checkout -b fm/' "$brief" | head -1 | cut -d: -f1)
  if [ -z "$iso" ] || [ -z "$br" ]; then
    fail "brief missing assertion ($iso) or branch step ($br)"
  fi
  [ "$iso" -lt "$br" ] || fail "isolation assertion (line $iso) must precede the branch step (line $br)"
  pass "fm-brief: ship brief asserts isolation before an idempotent branch setup"
}

# --- GUARD 1b: fm-spawn isolation abort -------------------------------------

# A fake tmux that reports FM_FAKE_PANE_PATH as the post-`treehouse get` pane cwd
# (so the spawn's worktree-resolution loop resolves to a path we control), names
# the session on '#S', and swallows window ops. Echoes the fakebin dir.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    text=${5:-}
    case "$text" in
      *fm-spawn-prelude*|*fm-spawn-launch*) (bash -c "$text") >/dev/null 2>&1 || true ;;
    esac
    exit 0
    ;;
  has-session|new-session|new-window) exit 0 ;;
esac
exit 0
SH
  fm_fake_harnesses "$fakebin"
  chmod +x "$fakebin/tmux"
  # Invalid candidates now stay in the bounded poll instead of aborting on the
  # first transient path, so shadow sleep to keep timeout cases deterministic.
  fm_fake_exit0 "$fakebin" treehouse sleep
  printf '%s\n' "$fakebin"
}

run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex 2>&1
}

test_spawn_isolation_abort() {
  local home proj fakebin out status
  home="$TMP_ROOT/spawn-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake")
  # A genuine isolated linked worktree of the project, detached on the default.
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-wt" >/dev/null 2>&1
  mkdir -p "$TMP_ROOT/spawn-notgit" "$proj/sub"

  # Abort: the pane resolves to a plain non-git directory (not a worktree at all).
  out=$(run_spawn "$home" abort-notgit-dd4 "$proj" "$TMP_ROOT/spawn-notgit" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn into a non-worktree dir should abort"
  assert_contains "$out" "did not enter a worktree of the requested project within 60s" "non-worktree spawn lacked the bounded-timeout error"
  assert_absent "$home/state/abort-notgit-dd4.meta" "aborted spawn must not record meta"

  # Abort: the pane resolves INTO the primary checkout (a subdir of PROJ_ABS).
  out=$(run_spawn "$home" abort-primary-ee5 "$proj" "$proj/sub" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn landing inside the primary checkout should abort"
  assert_contains "$out" "did not enter a worktree of the requested project within 60s" "primary-checkout spawn lacked the bounded-timeout error"

  # Proceed: the pane resolves to a genuine, isolated worktree.
  out=$(run_spawn "$home" ok-isolated-ff6 "$proj" "$TMP_ROOT/spawn-wt" "$fakebin"); status=$?
  expect_code 0 "$status" "spawn into a genuine isolated worktree should succeed"
  assert_contains "$out" "spawned ok-isolated-ff6" "isolated spawn did not report success"
  assert_not_contains "$out" "did not yield an isolated worktree" "isolated spawn wrongly tripped the guard"
  pass "fm-spawn: aborts unless the resolved worktree is a genuine, isolated worktree"
}

# A sequencing fake tmux returns one pane cwd per poll, then repeats the last
# value when the sequence is exhausted.
# It records both the observed cwd values and every tmux command so the test can
# prove the harness launch happens only after the requested project's worktree.
make_spawn_sequence_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
case "$*" in
  *"#{pane_current_path}"*)
    count=$(cat "${FM_FAKE_PANE_COUNTER:?}" 2>/dev/null || printf '0')
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_FAKE_PANE_COUNTER"
    path=$(sed -n "${count}p" "${FM_FAKE_PANE_SEQUENCE:?}")
    [ -n "$path" ] || path=$(tail -n 1 "$FM_FAKE_PANE_SEQUENCE")
    printf '%s\n' "$path" >> "${FM_FAKE_PANE_READS:?}"
    [ -n "${FM_TMUX_REC:-}" ] && printf 'cwd %s\n' "$path" >> "$FM_TMUX_REC"
    printf '%s\n' "$path"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '@spawnwid\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    text=${5:-}
    case "$text" in
      *fm-spawn-prelude*|*fm-spawn-launch*) (bash -c "$text") >/dev/null 2>&1 || true ;;
    esac
    exit 0
    ;;
  has-session|new-session|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  fm_fake_harnesses "$fakebin"
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse sleep
  printf '%s\n' "$fakebin"
}

run_spawn_sequence() {
  local home=$1 id=$2 proj=$3 fakebin=$4 sequence=$5 counter=$6 reads=$7 rec=$8
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  printf '0\n' > "$counter"
  : > "$reads"
  : > "$rec"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_SEQUENCE="$sequence" \
    FM_FAKE_PANE_COUNTER="$counter" FM_FAKE_PANE_READS="$reads" \
    FM_TMUX_REC="$rec" TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude 2>&1
}

test_spawn_ignores_transient_unrelated_paths() {
  local home proj wt nongit unrelated fakebin sequence counter reads rec out status meta
  local last_cwd_line launch_line
  home="$TMP_ROOT/spawn-sequence-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-sequence-proj")
  wt="$TMP_ROOT/spawn-sequence-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  nongit="$TMP_ROOT/spawn-sequence-notgit"
  mkdir -p "$nongit"
  unrelated=$(make_repo "$TMP_ROOT/spawn-sequence-unrelated")
  fakebin=$(make_spawn_sequence_fakebin "$TMP_ROOT/spawn-sequence-fake")
  sequence="$TMP_ROOT/spawn-sequence.paths"
  counter="$TMP_ROOT/spawn-sequence.count"
  reads="$TMP_ROOT/spawn-sequence.reads"
  rec="$TMP_ROOT/spawn-sequence.tmux"
  printf '%s\n' "$proj" "$nongit" "$unrelated" "$wt" > "$sequence"

  out=$(run_spawn_sequence "$home" transient-cwd-gg7 "$proj" "$fakebin" "$sequence" "$counter" "$reads" "$rec"); status=$?
  expect_code 0 "$status" "spawn should ignore transient unrelated cwd values and reach the project worktree"
  printf '%s\n' "$proj" "$nongit" "$unrelated" "$wt" > "$TMP_ROOT/spawn-sequence.expected"
  diff -u "$TMP_ROOT/spawn-sequence.expected" "$reads" >/dev/null \
    || fail "spawn did not poll through the deterministic transient cwd sequence"
  meta="$home/state/transient-cwd-gg7.meta"
  assert_grep "worktree=$wt" "$meta" "spawn metadata did not name the requested project's linked worktree"
  assert_no_grep "$unrelated" "$meta" "spawn metadata named the unrelated Git repository"
  assert_present "$wt/.claude/settings.local.json" "spawn did not configure the harness in the requested project's worktree"
  assert_absent "$unrelated/.claude/settings.local.json" "spawn configured the harness in the unrelated Git repository"
  last_cwd_line=$(grep -n '^cwd ' "$rec" | tail -n 1 | cut -d: -f1)
  launch_line=$(grep -n -F '.fm-spawn-launch.sh' "$rec" | tail -n 1 | cut -d: -f1)
  [ -n "$last_cwd_line" ] && [ -n "$launch_line" ] && [ "$last_cwd_line" -lt "$launch_line" ] \
    || fail "harness launch did not occur after the correct worktree cwd was observed"
  assert_contains "$out" "worktree=$wt" "spawn result did not report the requested project's linked worktree"
  rm -rf "/tmp/fm-transient-cwd-gg7"
  pass "fm-spawn: ignores transient non-Git and unrelated-Git cwd values before launching in the project worktree"
}

test_spawn_times_out_on_unrelated_repo() {
  local home proj unrelated fakebin sequence counter reads rec out status polls
  home="$TMP_ROOT/spawn-unrelated-timeout-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-unrelated-timeout-proj")
  unrelated=$(make_repo "$TMP_ROOT/spawn-unrelated-timeout-repo")
  fakebin=$(make_spawn_sequence_fakebin "$TMP_ROOT/spawn-unrelated-timeout-fake")
  sequence="$TMP_ROOT/spawn-unrelated-timeout.paths"
  counter="$TMP_ROOT/spawn-unrelated-timeout.count"
  reads="$TMP_ROOT/spawn-unrelated-timeout.reads"
  rec="$TMP_ROOT/spawn-unrelated-timeout.tmux"
  printf '%s\n' "$unrelated" > "$sequence"

  out=$(run_spawn_sequence "$home" unrelated-timeout-hh8 "$proj" "$fakebin" "$sequence" "$counter" "$reads" "$rec"); status=$?
  expect_code 1 "$status" "spawn should time out when every cwd candidate is an unrelated Git repository"
  assert_contains "$out" "did not enter a worktree of the requested project within 60s" "unrelated-repo timeout lacked the bounded-timeout error"
  assert_contains "$out" "last observed path '$unrelated'" "unrelated-repo timeout did not report the last observed pane path"
  assert_contains "$out" "expected '" "unrelated-repo timeout did not report the expected Git common directory"
  assert_absent "$home/state/unrelated-timeout-hh8.meta" "unrelated-repo timeout must not record metadata"
  assert_absent "$unrelated/.claude/settings.local.json" "unrelated-repo timeout configured a harness outside the requested project"
  polls=$(wc -l < "$reads" | tr -d ' ')
  [ "$polls" = 60 ] || fail "unrelated-repo timeout should exhaust 60 polls, got $polls"
  pass "fm-spawn: exhausts the bounded poll when only unrelated Git repositories appear"
}

test_spawn_fails_fast_on_non_git_project() {
  local home proj fakebin sequence counter reads rec out status polls
  home="$TMP_ROOT/spawn-nongit-proj-home"
  mkdir -p "$home/data"
  proj="$TMP_ROOT/spawn-nongit-proj"
  mkdir -p "$proj"
  fakebin=$(make_spawn_sequence_fakebin "$TMP_ROOT/spawn-nongit-proj-fake")
  sequence="$TMP_ROOT/spawn-nongit-proj.paths"
  counter="$TMP_ROOT/spawn-nongit-proj.count"
  reads="$TMP_ROOT/spawn-nongit-proj.reads"
  rec="$TMP_ROOT/spawn-nongit-proj.tmux"
  printf '%s\n' "$proj" > "$sequence"

  out=$(run_spawn_sequence "$home" nongit-proj-jj9 "$proj" "$fakebin" "$sequence" "$counter" "$reads" "$rec"); status=$?
  expect_code 1 "$status" "spawn of a non-git project should fail fast"
  assert_contains "$out" "cannot resolve the Git common directory" "non-git project spawn lacked the fail-fast error"
  assert_absent "$home/state/nongit-proj-jj9.meta" "non-git project spawn must not record metadata"
  polls=$(wc -l < "$reads" | tr -d ' ')
  [ "$polls" = 0 ] || fail "non-git project spawn should abort before any worktree poll, got $polls polls"
  ! grep -q '^tmux new-window' "$rec" || fail "non-git project spawn should abort before creating a window"
  pass "fm-spawn: fails fast when the requested project's Git common directory is unresolvable"
}

# --- GUARD 1c: fm-spawn tmux window construction ----------------------------

# The prevention guard also depends on fm-spawn building robust tmux commands
# under a non-default tmux config (base-index 1, automatic-rename on). A RECORDING
# fake tmux logs every invocation and returns a sentinel window id, so these
# assertions pin the command construction deterministically, with no live tmux:
#   - window creation targets the session with a trailing colon (append form), so
#     tmux appends at the next free index instead of the active window index, which
#     collides under base-index 1;
#   - the window id is captured (-P -F #{window_id}) and automatic-rename/allow-rename
#     are disabled so the fm-<id> name survives treehouse cd'ing into the worktree;
#   - the treehouse-get send-keys and the worktree wait loop target that stable
#     window id, never the (possibly-renamed) name - a lost name would let
#     display-message fall back to the active client's window and misread firstmate's
#     OWN pane as the worktree, tangling a hook into the primary checkout.
make_spawn_record_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '%s\n' "@spawnwid"; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    text=${5:-}
    case "$text" in
      *fm-spawn-prelude*|*fm-spawn-launch*) (bash -c "$text") >/dev/null 2>&1 || true ;;
    esac
    exit 0
    ;;
  has-session|new-session|set-window-option) exit 0 ;;
esac
exit 0
SH
  fm_fake_harnesses "$fakebin"
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn_record() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5 rec=$6
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    FM_TMUX_REC="$rec" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex 2>&1
}

# The identity fixture can report a dead or live agent for one recorded target
# and records the backend commands so adoption can be distinguished from a fresh
# treehouse acquisition.
make_spawn_identity_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
target=
previous=
for arg in "$@"; do
  if [ "$previous" = -t ]; then
    target=$arg
    previous=
  else
    previous=$arg
  fi
done
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*)
    if [ -n "${FM_FAKE_ENDPOINT_GONE_TARGET:-}" ] && [ "$target" = "$FM_FAKE_ENDPOINT_GONE_TARGET" ]; then
      exit 1
    fi
    if [ -n "${FM_FAKE_AGENT_TARGET:-}" ] && [ "$target" = "$FM_FAKE_AGENT_TARGET" ]; then
      printf '%s\n' "${FM_FAKE_AGENT_COMMAND:-bash}"
    else
      printf 'bash\n'
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message)
    if [ -n "${FM_FAKE_ENDPOINT_GONE_TARGET:-}" ] && ! grep -q 'new-window' "$FM_TMUX_REC"; then
      case "$*" in
        *"$FM_FAKE_ENDPOINT_GONE_TARGET"*) exit 1 ;;
      esac
    fi
    printf 'firstmate\n'
    exit 0
    ;;
  new-window) printf '@spawnwid\n'; exit 0 ;;
  send-keys)
    text=${5:-}
    case "$text" in
      *fm-spawn-prelude*|*fm-spawn-launch*) (bash -c "$text") >/dev/null 2>&1 || true ;;
    esac
    exit 0
    ;;
  list-windows|has-session|new-session|set-window-option) exit 0 ;;
esac
exit 0
SH
  fm_fake_harnesses "$fakebin"
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse sleep
  printf '%s\n' "$fakebin"
}

run_spawn_identity() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5 rec=$6 agent_target=$7 agent_command=$8
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" \
    FM_FAKE_AGENT_TARGET="$agent_target" FM_FAKE_AGENT_COMMAND="$agent_command" \
    FM_FAKE_ENDPOINT_GONE_TARGET="${FM_FAKE_ENDPOINT_GONE_TARGET:-}" \
    FM_TMUX_REC="$rec" TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex 2>&1
}

write_spawn_meta() {
  local home=$1 id=$2 proj=$3 wt=$4 window=$5
  mkdir -p "$home/state"
  {
    printf 'window=%s\n' "$window"
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$proj"
    printf 'kind=ship\n'
  } > "$home/state/$id.meta"
}

test_spawn_reuses_recorded_worktree() {
  local home proj wt1 wt2 wt1_real fakebin rec first second first_status second_status gets
  home="$TMP_ROOT/spawn-identity-reuse-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-identity-reuse-proj")
  wt1="$TMP_ROOT/spawn-identity-reuse-wt1"
  wt2="$TMP_ROOT/spawn-identity-reuse-wt2"
  git -C "$proj" worktree add -q --detach "$wt1" >/dev/null 2>&1
  git -C "$proj" worktree add -q --detach "$wt2" >/dev/null 2>&1
  wt1_real=$(cd "$wt1" && pwd -P)
  fakebin=$(make_spawn_identity_fakebin "$TMP_ROOT/spawn-identity-reuse-fake")
  rec="$TMP_ROOT/spawn-identity-reuse.tmux"
  : > "$rec"

  first=$(run_spawn_identity "$home" reuse-identity-aa1 "$proj" "$wt1" "$fakebin" "$rec" '' bash); first_status=$?
  expect_code 0 "$first_status" "initial identity fixture spawn should succeed"
  assert_contains "$first" "spawned reuse-identity-aa1" "initial identity fixture spawn did not create task metadata"
  second=$(run_spawn_identity "$home" reuse-identity-aa1 "$proj" "$wt2" "$fakebin" "$rec" '' bash); second_status=$?
  expect_code 0 "$second_status" "same-id respawn should reuse the recorded worktree"
  assert_contains "$second" "reusing recorded worktree for task reuse-identity-aa1" "same-id respawn did not report recorded-worktree adoption"
  assert_contains "$second" "worktree=$wt1_real" "same-id respawn did not return the original worktree"
  assert_grep 'new-window' "$rec" "same-id respawn did not create its new pane"
  assert_grep "-c $wt1_real" "$rec" "same-id respawn did not create its new pane in the recorded worktree"
  gets=$(grep -c 'treehouse get' "$rec" || true)
  [ "$gets" = 1 ] || fail "same-id respawn called treehouse get $gets times instead of only on the initial spawn"
  assert_absent "$home/state/reuse-identity-aa1.spawn.lock" "spawn lock was not released after same-id adoption"
  pass "fm-spawn: reuses the recorded worktree and skips a second treehouse acquisition"
}

test_spawn_reuses_after_recorded_endpoint_gone() {
  local home proj wt wt_real fakebin rec out rc target
  home="$TMP_ROOT/spawn-identity-gone-endpoint-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-identity-gone-endpoint-proj")
  wt="$TMP_ROOT/spawn-identity-gone-endpoint-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  wt_real=$(cd "$wt" && pwd -P)
  target="firstmate:fm-gone-identity-ab2"
  write_spawn_meta "$home" gone-identity-ab2 "$proj" "$wt" "$target"
  fakebin=$(make_spawn_identity_fakebin "$TMP_ROOT/spawn-identity-gone-endpoint-fake")
  rec="$TMP_ROOT/spawn-identity-gone-endpoint.tmux"
  : > "$rec"

  set +e
  out=$(FM_FAKE_ENDPOINT_GONE_TARGET="$target" run_spawn_identity "$home" gone-identity-ab2 "$proj" "$TMP_ROOT/unused" "$fakebin" "$rec" '' bash)
  rc=$?
  set -e
  expect_code 0 "$rc" "spawn should reuse a worktree after its old endpoint is gone"
  assert_contains "$out" "worktree=$wt_real" "gone-endpoint respawn did not keep the recorded worktree"
  assert_no_grep 'treehouse get' "$rec" "gone-endpoint respawn should not acquire a fresh treehouse worktree"
  pass "fm-spawn: reuses the recorded worktree after the old pane is gone"
}

test_spawn_refuses_live_recorded_holder() {
  local home proj wt fakebin rec out rc target
  home="$TMP_ROOT/spawn-identity-live-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-identity-live-proj")
  wt="$TMP_ROOT/spawn-identity-live-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  target="firstmate:fm-live-identity-bb2"
  write_spawn_meta "$home" live-identity-bb2 "$proj" "$wt" "$target"
  fakebin=$(make_spawn_identity_fakebin "$TMP_ROOT/spawn-identity-live-fake")
  rec="$TMP_ROOT/spawn-identity-live.tmux"
  : > "$rec"

  set +e
  out=$(run_spawn_identity "$home" live-identity-bb2 "$proj" "$TMP_ROOT/unused" "$fakebin" "$rec" "$target" codex)
  rc=$?
  set -e
  expect_code 1 "$rc" "spawn should refuse a live recorded holder"
  assert_contains "$out" "held by agent task live-identity-bb2" "live-holder refusal did not identify the task holding the worktree"
  assert_no_grep 'new-window' "$rec" "live-holder refusal allocated a backend endpoint"
  assert_absent "$home/state/live-identity-bb2.spawn.lock" "spawn lock was not released after live-holder refusal"
  pass "fm-spawn: refuses to take over a worktree held by a live recorded agent"
}

test_spawn_refuses_other_task_holder() {
  local home proj wt fakebin rec out rc holder_target
  home="$TMP_ROOT/spawn-identity-other-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-identity-other-proj")
  wt="$TMP_ROOT/spawn-identity-other-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  write_spawn_meta "$home" adopt-identity-cc3 "$proj" "$wt" "firstmate:fm-adopt-identity-cc3"
  holder_target="firstmate:fm-other-identity-dd4"
  write_spawn_meta "$home" other-identity-dd4 "$proj" "$wt" "$holder_target"
  fakebin=$(make_spawn_identity_fakebin "$TMP_ROOT/spawn-identity-other-fake")
  rec="$TMP_ROOT/spawn-identity-other.tmux"
  : > "$rec"

  set +e
  out=$(run_spawn_identity "$home" adopt-identity-cc3 "$proj" "$TMP_ROOT/unused" "$fakebin" "$rec" "$holder_target" codex)
  rc=$?
  set -e
  expect_code 1 "$rc" "spawn should refuse another task's live holder"
  assert_contains "$out" "held by agent task other-identity-dd4" "other-holder refusal did not identify the other task"
  assert_no_grep 'new-window' "$rec" "other-holder refusal allocated a backend endpoint"
  pass "fm-spawn: refuses to take over a worktree recorded as held by another live task"
}

test_spawn_refuses_concurrent_same_id() {
  local home proj fakebin rec out rc id
  home="$TMP_ROOT/spawn-identity-lock-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-identity-lock-proj")
  fakebin=$(make_spawn_identity_fakebin "$TMP_ROOT/spawn-identity-lock-fake")
  rec="$TMP_ROOT/spawn-identity-lock.tmux"
  : > "$rec"
  id=lock-identity-ff4
  mkdir -p "$home/state/$id.spawn.lock"
  printf '%s\n' "$$" > "$home/state/$id.spawn.lock/pid"

  set +e
  out=$(run_spawn_identity "$home" "$id" "$proj" "$TMP_ROOT/unused" "$fakebin" "$rec" '' bash)
  rc=$?
  set -e
  expect_code 1 "$rc" "concurrent same-id spawn should be refused"
  assert_contains "$out" "another spawn for task $id is in progress" "concurrent same-id refusal did not identify the active spawn"
  assert_no_grep 'new-window' "$rec" "concurrent same-id refusal allocated a backend endpoint"
  pass "fm-spawn: serializes concurrent respawns of the same task id"
}

test_spawn_warns_before_fresh_worktree_after_loss() {
  local home proj wt fakebin rec out rc
  home="$TMP_ROOT/spawn-identity-missing-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-identity-missing-proj")
  wt="$TMP_ROOT/spawn-identity-missing-new-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  write_spawn_meta "$home" missing-identity-ee5 "$proj" "$TMP_ROOT/spawn-identity-missing-gone" "firstmate:fm-missing-identity-ee5"
  fakebin=$(make_spawn_identity_fakebin "$TMP_ROOT/spawn-identity-missing-fake")
  rec="$TMP_ROOT/spawn-identity-missing.tmux"
  : > "$rec"

  out=$(run_spawn_identity "$home" missing-identity-ee5 "$proj" "$wt" "$fakebin" "$rec" '' bash); rc=$?
  expect_code 0 "$rc" "spawn should request a fresh worktree when the recorded path is gone"
  assert_contains "$out" "requesting a fresh treehouse worktree" "missing-worktree fallback did not report the fresh acquisition"
  assert_contains "$out" "uncommitted work may still remain" "missing-worktree fallback did not warn about possible WIP"
  assert_contains "$out" "will not detach it automatically" "missing-worktree fallback did not promise branch safety"
  assert_grep 'treehouse get' "$rec" "missing-worktree fallback did not acquire through treehouse"
  pass "fm-spawn: warns about stranded WIP before requesting a fresh treehouse worktree"
}

test_spawn_tmux_window_construction() {
  local home proj fakebin rec wt out status
  home="$TMP_ROOT/spawn-rec-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-rec-proj")
  fakebin=$(make_spawn_record_fakebin "$TMP_ROOT/spawn-rec-fake")
  rec="$TMP_ROOT/spawn-rec.log"
  : > "$rec"
  wt="$TMP_ROOT/spawn-rec-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1

  out=$(run_spawn_record "$home" rec-win-gg7 "$proj" "$wt" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "spawn into a genuine worktree should succeed"
  assert_contains "$out" "spawned rec-win-gg7" "recording spawn did not report success"

  # Bug 1 fix: append-form window creation (trailing colon on the session target).
  assert_grep "new-window -dP -F #{window_id} -t firstmate: -n fm-rec-win-gg7" "$rec" \
    "new-window must append at the session (trailing colon) and capture the window id"
  assert_no_grep "new-window -dP -F #{window_id} -t firstmate -n" "$rec" \
    "new-window must not target the bare session name (collides under base-index 1)"

  # Bug 2 fix (a): pin the window name against automatic-rename / allow-rename.
  assert_grep "set-window-option -t @spawnwid automatic-rename off" "$rec" \
    "must disable automatic-rename on the spawned window"
  assert_grep "set-window-option -t @spawnwid allow-rename off" "$rec" \
    "must disable allow-rename on the spawned window"

  # Bug 2 fix (b): treehouse-get and the worktree wait loop target the stable id.
  assert_grep "send-keys -t @spawnwid treehouse get Enter" "$rec" \
    "treehouse get must be sent to the stable window id"
  assert_grep "display-message -p -t @spawnwid #{pane_current_path}" "$rec" \
    "the worktree wait loop must query the stable window id, not the name"

  pass "fm-spawn: appends windows by session-colon, pins the name, and targets the window id"
}

test_lib_classification
test_guard_banner
test_bootstrap_line
test_brief_assertion_precedes_branch
test_spawn_times_out_on_unrelated_repo
test_spawn_fails_fast_on_non_git_project
test_spawn_ignores_transient_unrelated_paths
test_spawn_isolation_abort
test_spawn_tmux_window_construction
test_spawn_reuses_recorded_worktree
test_spawn_reuses_after_recorded_endpoint_gone
test_spawn_refuses_live_recorded_holder
test_spawn_refuses_other_task_holder
test_spawn_refuses_concurrent_same_id
test_spawn_warns_before_fresh_worktree_after_loss
