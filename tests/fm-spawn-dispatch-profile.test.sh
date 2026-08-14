#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh concrete dispatch profile flags.
#
# These tests drive fm-spawn through meta writing and launch construction with a
# fake tmux pane and a real isolated git worktree. The fake tmux captures the
# literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would run without starting any real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)

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
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          case "$a" in
            *fm-spawn-prelude*|*fm-spawn-launch*)
              (bash -c "$a") >/dev/null 2>&1 || true
              ;;
          esac
          launch_script=$(printf '%s\n' "$a" | sed -n "s/.*\\. '\\([^']*\\.fm-spawn-launch\\.sh\\)'.*/\\1/p")
          if [ -n "$launch_script" ] && [ -f "$launch_script" ]; then
            tail -n +2 "$launch_script" >> "$FM_FAKE_LAUNCH_LOG"
          fi
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_codex_catalog "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    CODEX_HOME="$home/codex-home" \
    "$SPAWN" "$@" 2>&1
}

# fm-spawn reads codex's own config.toml to resolve the effective model when no
# --model was passed. CODEX_HOME is pinned per case so the developer's real
# ~/.codex/config.toml never leaks into these assertions.
set_codex_config_model() {
  local home=$1 model=$2
  mkdir -p "$home/codex-home"
  printf 'model = "%s"\n' "$model" > "$home/codex-home/config.toml"
}

# Writes a config.toml body verbatim, for the TOML forms set_codex_config_model's
# double-quoted shape does not cover.
write_codex_config() {
  local home=$1 body=$2
  mkdir -p "$home/codex-home"
  printf '%s\n' "$body" > "$home/codex-home/config.toml"
}

# fm-spawn's codex catalog probe needs jq; without it the probe reports the
# model's levels as unknown and the gate takes its fail-safe path instead of the
# one under test. Skip rather than report a false regression, matching
# tests/fm-backend-herdr.test.sh and tests/fm-backend-cmux.test.sh.
require_jq() {
  local what=$1
  command -v jq >/dev/null 2>&1 && return 0
  echo "skip: $what (jq not found; fm-spawn's codex model catalog probe needs it)"
  return 1
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

assert_meta_profile() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

test_no_profile_keeps_claude_launch_unchanged() {
  local rec id out status expected launch
  id=profile-off-z1
  rec=$(make_spawn_case profile-off claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default

  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "no --model/--effort records defaults and keeps the claude launch byte-identical"
}

test_active_dispatch_profile_requires_explicit_harness_for_ship() {
  local rec id out status
  id=profile-required-ship-z11
  rec=$(make_spawn_case profile-required-ship claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "spawn did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "ship refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for ship spawns"
}

test_active_dispatch_profile_requires_explicit_harness_for_scout() {
  local rec id out status
  id=profile-required-scout-z12
  rec=$(make_spawn_case profile-required-scout claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 1 "$status" "scout spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "scout refusal did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "scout refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for scout spawns"
}

test_active_dispatch_profile_allows_explicit_harness() {
  local rec id out status launch
  id=profile-explicit-z13
  rec=$(make_spawn_case profile-explicit claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "explicit harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report explicit codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "explicit harness launch did not thread model and effort"
  pass "active crew-dispatch profile allows an explicit resolved harness"
}

test_active_dispatch_profile_allows_positional_harness() {
  local rec id out status
  id=profile-positional-z14
  rec=$(make_spawn_case profile-positional claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "positional harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report positional codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  pass "active crew-dispatch profile allows the legacy positional harness form"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag")
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "custom-agent --flag" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  pass "active crew-dispatch profile allows the raw launch-command escape hatch"
}

test_raw_launch_command_warns_when_profile_axes_are_ignored() {
  local rec id out status launch
  id=profile-raw-warn-z16
  rec=$(make_spawn_case profile-raw-warn claude "$id")
  read_case_record "$rec"

  # The raw first word is a known adapter name on purpose: the raw branch must own
  # the warning, not the per-harness effort gate for a launch it never builds.
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "grok --always-approve" --model grok-4 --effort max)
  status=$?
  expect_code 0 "$status" "raw launch with profile axes should still launch"
  assert_contains "$out" "warning: ignoring --model grok-4: the raw launch command controls the entire launch" \
    "raw launch must warn that --model is ignored"
  assert_contains "$out" "warning: ignoring --effort max: the raw launch command controls the entire launch" \
    "raw launch must warn that --effort is ignored"
  assert_not_contains "$out" "warning: omitting grok effort" \
    "raw launch must not emit the per-harness effort warning"
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "grok --always-approve" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  pass "raw launch command warns on stderr and launches unchanged when profile axes are passed"
}

test_claude_threads_model_and_effort() {
  local rec id out status launch
  id=profile-claude-z2
  rec=$(make_spawn_case profile-claude claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "claude spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude sonnet high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'sonnet' --effort 'high'" \
    "claude launch did not thread model and effort flags"
  pass "claude receives --model and --effort profile flags"
}

test_codex_threads_model_and_effort() {
  local rec id out status launch
  id=profile-codex-z3
  rec=$(make_spawn_case profile-codex codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5.5 --effort high)
  status=$?
  expect_code 0 "$status" "codex spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5.5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5.5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not thread model and reasoning effort config"
  pass "codex receives --model and model_reasoning_effort profile flags"
}

test_codex_threads_max_effort_for_max_capable_model() {
  local rec id out status launch
  require_jq "codex threads max effort for a max-capable model" || return 0
  id=profile-codex-max-z4
  rec=$(make_spawn_case profile-codex-max codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5.6-luna --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn with supported max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5.6-luna max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5.6-luna' -c 'model_reasoning_effort=\"max\"' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not thread supported max reasoning effort"
  assert_not_contains "$out" "warning: omitting codex effort" "codex max on a max-capable model must not warn"
  pass "codex threads max effort for a model whose catalog advertises max"
}

test_codex_omits_max_for_model_without_max() {
  local rec id out status launch
  require_jq "codex omits max for a model whose catalog lacks it" || return 0
  id=profile-codex-nomax-z4
  rec=$(make_spawn_case profile-codex-nomax codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5.5 --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn with a model that lacks max should still launch"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5.5 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5.5' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not preserve the model flag when max was omitted"
  assert_not_contains "$launch" "model_reasoning_effort" \
    "codex launch must omit max for a model whose catalog lacks it"
  assert_contains "$out" "warning: omitting codex effort max for model gpt-5.5: codex debug models advertises only low,medium,high,xhigh for this model" \
    "codex must warn naming harness, model, effort, and reason when the model lacks the level"
  pass "codex omits max for a model whose catalog lacks it and warns with the reason"
}

test_codex_omits_max_when_catalog_unreadable() {
  local rec id out status launch
  id=profile-codex-nocat-z4
  rec=$(make_spawn_case profile-codex-nocat codex "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/codex-models.json"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5.6-luna --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn should succeed when the model catalog cannot be read"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5.6-luna' --dangerously-bypass-approvals-and-sandbox" \
    "an unreadable catalog must still preserve the model flag"
  assert_not_contains "$launch" "model_reasoning_effort" \
    "an unreadable catalog must not pass max unconfirmed"
  assert_contains "$out" "warning: omitting codex effort max for model gpt-5.6-luna: the effective model's advertised reasoning levels are unknown, so max cannot be confirmed" \
    "an unreadable catalog must warn that max could not be confirmed"
  pass "codex omits max when the model catalog cannot be read"
}

test_codex_keeps_xhigh_when_catalog_unreadable() {
  local rec id out status launch
  id=profile-codex-nocat-xhigh-z4
  rec=$(make_spawn_case profile-codex-nocat-xhigh codex "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/codex-models.json"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5.6-luna --effort xhigh)
  status=$?
  expect_code 0 "$status" "codex spawn should succeed when the model catalog cannot be read"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5.6-luna' -c 'model_reasoning_effort=\"xhigh\"' --dangerously-bypass-approvals-and-sandbox" \
    "an unreadable catalog must not drop a level every catalog model advertises"
  assert_not_contains "$out" "warning: omitting codex effort" "xhigh must not warn when the catalog is unreadable"
  pass "codex keeps xhigh when the model catalog cannot be read"
}

test_codex_resolves_default_model_from_codex_config_for_max() {
  local rec id out status launch
  require_jq "codex resolves its configured default model for max" || return 0
  id=profile-codex-cfgmax-z4
  rec=$(make_spawn_case profile-codex-cfgmax codex "$id")
  read_case_record "$rec"
  set_codex_config_model "$HOME_DIR" gpt-5.6-luna

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn without --model should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex default max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex -c 'model_reasoning_effort=\"max\"' --dangerously-bypass-approvals-and-sandbox" \
    "codex did not thread max for a configured default model that advertises it"
  assert_not_contains "$out" "warning: omitting codex effort" \
    "a configured max-capable default model must not warn"
  pass "codex resolves its configured default model and threads max when that model advertises it"
}

# TOML accepts literal single-quoted strings as well as basic double-quoted ones,
# and a `profile =` key belongs to whichever table it sits under, so a later
# table's key must not mask the top-level model. Each row is a distinct valid
# config.toml whose top-level model is the max-capable gpt-5.6-luna.
test_codex_resolves_default_model_across_toml_forms() {
  local rec id out status launch name body n=0
  require_jq "codex resolves its configured default model across TOML forms" || return 0
  while IFS='^' read -r name body; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    id="profile-codex-toml-$n-z4"
    rec=$(make_spawn_case "profile-codex-toml-$n" codex "$id")
    read_case_record "$rec"
    write_codex_config "$HOME_DIR" "$(printf '%b' "$body")"

    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --effort max)
    status=$?
    expect_code 0 "$status" "$name: codex spawn without --model should succeed"
    launch=$(cat "$LAUNCH_LOG")
    assert_contains "$launch" "codex -c 'model_reasoning_effort=\"max\"' --dangerously-bypass-approvals-and-sandbox" \
      "$name: codex did not resolve the top-level model and thread max"
    assert_not_contains "$out" "warning: omitting codex effort" "$name: a max-capable configured model must not warn"
  done <<'ROWS'
literal single-quoted string^model = 'gpt-5.6-luna'
double-quoted with a trailing comment^model = "gpt-5.6-luna" # pinned
padded single-quoted string^  model   =   'gpt-5.6-luna'
profile key under a later table^model = 'gpt-5.6-luna'\n[tui]\nprofile = "something"
ROWS
  [ "$n" -eq 4 ] || fail "expected 4 TOML forms exercised, got $n"
  pass "codex resolves a top-level model across valid TOML quoting forms and table scoping"
}

# A top-level `profile =` selects a named profile whose own model key this parser
# deliberately does not follow, so the effective model stays unresolved and max
# fails safe rather than being read off the wrong key.
test_codex_omits_max_when_a_top_level_profile_is_selected() {
  local rec id out status launch
  id=profile-codex-tomlprofile-z4
  rec=$(make_spawn_case profile-codex-tomlprofile codex "$id")
  read_case_record "$rec"
  write_codex_config "$HOME_DIR" "$(printf 'profile = "work"\nmodel = "gpt-5.6-luna"\n')"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn with a selected profile should still launch"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "model_reasoning_effort" \
    "a selected profile leaves the effective model unresolved, so max must not pass"
  assert_contains "$out" "warning: omitting codex effort max for model default: the effective model's advertised reasoning levels are unknown, so max cannot be confirmed" \
    "codex must warn that max could not be confirmed when a profile is selected"
  pass "codex omits max when a top-level profile selection leaves the effective model unresolved"
}

test_codex_omits_max_for_configured_default_model_without_max() {
  local rec id out status launch
  require_jq "codex omits max for a configured default model that lacks it" || return 0
  id=profile-codex-cfgnomax-z4
  rec=$(make_spawn_case profile-codex-cfgnomax codex "$id")
  read_case_record "$rec"
  set_codex_config_model "$HOME_DIR" gpt-5.5

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn without --model should still launch"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex default max
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "model_reasoning_effort" \
    "an unselected model must not bypass the per-model gate"
  assert_contains "$out" "warning: omitting codex effort max for model gpt-5.5: codex debug models advertises only low,medium,high,xhigh for this model" \
    "codex must warn naming the resolved effective model when it lacks max"
  pass "codex omits max when its configured default model lacks it"
}

test_codex_omits_max_when_no_model_resolves() {
  local rec id out status launch
  id=profile-codex-nomodel-z4
  rec=$(make_spawn_case profile-codex-nomodel codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn without a resolvable model should still launch"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "model_reasoning_effort" \
    "max must not reach the launch when no effective model resolves"
  assert_contains "$out" "warning: omitting codex effort max for model default: the effective model's advertised reasoning levels are unknown, so max cannot be confirmed" \
    "codex must warn that max could not be confirmed when no model resolves"
  pass "codex omits max when neither a flag nor its config resolves an effective model"
}

# `ultra` is rejected by the harness-agnostic --effort axis validator, not by any
# codex-specific branch, so it never reaches effort_flag_for_harness at all. Cover
# it across harnesses so the rejection is not misread as a codex-only gate.
test_effort_axis_rejects_ultra_for_every_harness() {
  local rec id out status launch harness n=0
  for harness in codex claude pi; do
    n=$((n + 1))
    id="profile-ultra-$harness-z4"
    rec=$(make_spawn_case "profile-ultra-$harness" "$harness" "$id")
    read_case_record "$rec"

    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --effort ultra)
    status=$?
    expect_code 1 "$status" "$harness spawn with unsupported ultra effort should fail clearly"
    assert_contains "$out" "error: --effort must be one of low, medium, high, xhigh, max" \
      "$harness ultra rejection must explain the accepted firstmate effort axis"
    assert_absent "$HOME_DIR/state/$id.meta" "$harness ultra refusal should happen before meta is written"
    launch=$(cat "$LAUNCH_LOG")
    [ -z "$launch" ] || fail "$harness ultra rejection must not launch a pane"
  done
  [ "$n" -eq 3 ] || fail "expected 3 harnesses exercised, got $n"
  pass "the --effort axis validator rejects ultra for every harness before any launch"
}

test_grok_threads_model_and_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-z5
  rec=$(make_spawn_case profile-grok grok "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort high)
  status=$?
  expect_code 0 "$status" "grok spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' --reasoning-effort 'high'" \
    "grok launch did not thread model and reasoning-effort flags"
  assert_not_contains "$launch" "--effort" "grok launch must use --reasoning-effort, not --effort"
  pass "grok receives --model and --reasoning-effort profile flags"
}

test_grok_omits_invalid_max_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-max-z6
  rec=$(make_spawn_case profile-grok-max grok "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort max)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported max reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$(cat " \
    "grok launch did not preserve the model flag when max effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported max reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  assert_contains "$out" "warning: omitting grok effort max for model grok-4: grok 0.2.73 rejects --reasoning-effort max" \
    "grok launch must warn naming harness, model, effort, and reason when max is omitted"
  pass "grok omits unsupported max reasoning effort"
}

test_opencode_threads_model_and_ignores_effort_axis() {
  local rec id out status launch
  id=profile-opencode-z7
  rec=$(make_spawn_case profile-opencode opencode "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model anthropic/claude-sonnet-4-5 --effort high)
  status=$?
  expect_code 0 "$status" "opencode spawn with model and ignored effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" opencode anthropic/claude-sonnet-4-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "opencode --model 'anthropic/claude-sonnet-4-5' --prompt" \
    "opencode launch did not thread model"
  assert_not_contains "$launch" "--effort" "opencode launch must not pass unsupported --effort"
  assert_not_contains "$launch" "--variant" "opencode launch must not pass run-only --variant"
  assert_not_contains "$launch" "--thinking" "opencode launch must not pass pi thinking flag"
  assert_contains "$out" "warning: omitting opencode effort high for model anthropic/claude-sonnet-4-5: the interactive opencode --prompt launch has no verified effort flag" \
    "opencode launch must warn naming harness, model, effort, and reason when the effort axis is omitted"
  pass "opencode receives --model and omits the unsupported effort axis"
}

test_pi_threads_max_effort() {
  local rec id out status launch
  id=profile-pi-z8
  rec=$(make_spawn_case profile-pi pi "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with supported max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi sonnet max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "pi --model 'sonnet' --thinking 'max' -e" "pi launch did not thread model and max thinking"
  assert_not_contains "$out" "warning: omitting pi effort" "pi max should not emit an unsupported-effort warning"
  pass "pi threads supported max effort"
}

test_batch_forwards_shared_profile_flags() {
  local rec id1 id2 out status
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  pass "batch dispatch forwards shared --harness, --model, and --effort to every pair"
}

test_active_dispatch_profile_does_not_block_secondmate_launch() {
  local rec id sm out status
  id=profile-secondmate-z16
  rec=$(make_spawn_case profile-secondmate codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should be exempt from the dispatch-profile explicit harness requirement"
  assert_contains "$out" "spawned $id harness=codex kind=secondmate" "secondmate launch did not use secondmate harness resolution"
  assert_grep "kind=secondmate" "$HOME_DIR/state/$id.meta" "secondmate meta missing kind=secondmate"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex default default
  pass "active crew-dispatch profile does not block secondmate launches"
}

test_no_profile_keeps_claude_launch_unchanged
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_raw_launch_command_warns_when_profile_axes_are_ignored
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_threads_max_effort_for_max_capable_model
test_codex_omits_max_for_model_without_max
test_codex_omits_max_when_catalog_unreadable
test_codex_keeps_xhigh_when_catalog_unreadable
test_codex_resolves_default_model_from_codex_config_for_max
test_codex_resolves_default_model_across_toml_forms
test_codex_omits_max_when_a_top_level_profile_is_selected
test_codex_omits_max_for_configured_default_model_without_max
test_codex_omits_max_when_no_model_resolves
test_effort_axis_rejects_ultra_for_every_harness
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_opencode_threads_model_and_ignores_effort_axis
test_pi_threads_max_effort
test_batch_forwards_shared_profile_flags
test_active_dispatch_profile_does_not_block_secondmate_launch

echo "# all fm-spawn-dispatch-profile tests passed"
