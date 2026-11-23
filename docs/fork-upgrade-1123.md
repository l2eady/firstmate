# Upgrading the November 23 fork

The upgrade starts at `kunchenguid/firstmate` commit `427056c4181c41074ad24f051f79919330df0fa5`.
The live home assessed for this migration was `/Users/manaja/Downloads/projects/personal/firstmate` at `a6229fa1`.
The fork's newer `origin/main` was `7d62bc2f`.
The upgrade is delivered on `origin/upgrade/upstream-1123`.

## Re-applied behavior

| Change | Upstream entry points and fork evidence |
| --- | --- |
| Direct-push | [Registry](../bin/fm-project-mode.sh), [brief and promotion contract](../bin/fm-dod-lib.sh), [spawn](../bin/fm-spawn.sh), [PR registration](../bin/fm-pr-check.sh), [teardown](../bin/fm-teardown.sh), and [landing procedure](../.agents/skills/ship-landing/SKILL.md). Fork `1d005ed5` plus the prior operating contract. |
| Task resource ownership | [Spawn](../bin/fm-spawn.sh), [teardown](../bin/fm-teardown.sh), [orphan sweep](../bin/fm-resource-gc.sh), and [resource contract](teardown-resource-cleanup.md). Fork `61dfbbb7`, `a2a94ea3`, the resource part of `bda0a01d`, `0c800b32`, `6b1c5918`, `c1d8186c`, and `d4755a4a`. |
| Orphan test databases and anonymous Docker volumes | [Project hook caller](../bin/fm-test-db-sweep-lib.sh), [bootstrap](../bin/fm-bootstrap.sh), and [Docker cleanup](../bin/fm-resource-lib.sh). Fork `a6229fa1`. |
| Bare Docker command names | [Docker wrapper](../bin/fm-resource-docker.sh) keeps the executable PATH search and excludes wrapper aliases. Fork `6ffb9206`. |
| Low disk space warnings | [Bootstrap](../bin/fm-bootstrap.sh) and [watcher](../bin/fm-watch.sh) share the [home filesystem probe](../bin/fm-disk-lib.sh). Fork `2cdda2db`. Upstream lane capacity has a 5 GiB disk threshold, while this warning starts at 50 decimal GB and reaches the operator during an active session. |

These independent registry examples resolve to `direct-push on` and `direct-push off`, respectively.

```text
- x [direct-push +yolo] - example
- x [direct-push] - example
```

`direct-push` requires an `origin` remote and targets its advertised default branch.
A local branch or a remote topic branch cannot prove completion.
The worker uses the full commit ID in `done: pushed to <branch> as <sha>`.
The task's `+yolo` value is still carried in metadata.

## Dropped or superseded

- `28be0853` and the earlier AFK and agent-death series use older supervision paths. Upstream already has exact endpoint and agent-state probes in [watch](../bin/fm-watch.sh) (`wedge_dead_record` and `fm-crew-state.sh --reconcile`) and ledger reconciliation in [inactive reconcile](../bin/fm-inactive-reconcile.sh).
- `de84aa7d` addressed the fork's older Herdr test cleanup traps. Upstream's [lab helper](../bin/fm-herdr-lab.sh) and real-Herdr lane already own guarded teardown and tripwire handling.
- `ce415099` supplied fakes for the older tests. The upgraded suites already have per-harness fixture logic and a live gate in [tests/lib.sh](../tests/lib.sh).
- `43c7863e` documented the three November fixes. The Docker resolver and disk warning documentation follow the upgraded entry points above. The older supervision wording follows the upstream paths.
- `7d62bc2f` is the merge of those changes.
- `795bb9ef` and `24c4e30b` are superseded by upstream Treehouse leases, copy validation, and relaunch reuse.
- `666946e7` is replaced by the `config/status-archive` flag and `data/<id>/status.log`. Previous archives remain readable at `data/status-archive/`.
- The no-CI part of `bda0a01d` is covered by upstream's [crew state](../bin/fm-crew-state.sh) `no-checks` result.
- The tmux pause bookkeeping and empty pane fixes in `6ba5fb57` and `aa253a68` are outside the Herdr migration. Upstream has since changed the relevant task and endpoint inventory code.
- Dynamic Codex `max` is skipped. Upstream retains its `gpt-5.6-luna` exception, and the live `gpt-6.2-sol high` dispatch stays supported. Re-introducing the fork behavior would need catalog probing and consistent fallback across Codex launch paths.
- `f54ebec3`, `4393a334`, and `b748bb46` supplied guidance or notes for the older fork. The upgraded cleanup contract is documented separately, and upstream relaunch now keeps the existing worktree.
- The optional child-workspace label change was exploratory. Upstream's existing presentation identity and task ID display remain the migration baseline.

## Tool floors

| Tool | Required for this migration | Assessment version |
| --- | --- | --- |
| Git | 2.38 or newer for upstream's content-landed proof | Check with `git --version` |
| no-mistakes | 1.46.0 | 1.45.4 |
| gh-axi | 0.1.29 | 0.1.26 |
| quota-axi | 0.1.51 | 0.1.5 |
| lavish-axi | 0.1.77 for visual boards, 0.1.80 for confirmed replies | 0.1.38 |
| tasks-axi | 0.2.6 plus upstream's capabilities probe | 0.2.6 |
| Treehouse | `get --lease` support | 2.1.1 |
| Herdr | Protocol 14 for backend support, 19 for automatic presentation spaces | 0.8.0, protocol 19 |
| jq | Required by bootstrap and Herdr | Check with `jq --version` |

Upstream lint pins ShellCheck 0.11.0 and actionlint 1.7.12.
The GitHub Herdr CI lane pins Herdr 0.7.4 and checks protocol 16.
For the live cutover, use the presentation floor above.

## In-place cutover

Run these steps on the live home only when the captain schedules the switch.
Keep the home and project paths in place so the absolute references, existing Treehouse pools, and path-keyed harness state remain usable.

1. Stop dispatching and finish every task under the currently running fork. At assessment three tasks were in flight. Recheck the inventory at cutover because it can change. Land or explicitly resolve each task, then run the old `bin/fm-teardown.sh <id>`. If the old home is away, send a genuine message so its `afk` skill can clear the posture and stop the daemon. End the old firstmate only after tasks and wake obligations are drained. If its watcher persists, check the PID in `state/.watch.lock/pid` against the process and the recorded home identity, then signal just that confirmed watcher. Verify the watcher is gone, the home lock has no live holder, and no `state/*.meta` remains.
2. Run old `bin/fm-resource-gc.sh --dry-run`, then `bin/fm-resource-gc.sh`. Investigate each retained manifest or endpoint and confirm the task-labelled Docker resources are gone before switching. Let the owning project clean remaining test databases with its documented orphan-only command. Preserve unresolved metadata and use the old runtime to reconcile it.
3. Bring the tools above to their supported floors before dispatching. Make the backup private and record which refs it represents.

   ```bash
   fm_live=/Users/manaja/Downloads/projects/personal/firstmate
   umask 077
   fm_backup=$(mktemp -d "$HOME/fm-backup-1123.XXXXXX")
   git -C "$fm_live" status --short --untracked-files=no
   git -C "$fm_live" rev-parse main refs/remotes/origin/main >"$fm_backup/original-refs"
   git -C "$fm_live" tag fork-live-1123-backup main
   git -C "$fm_live" tag fork-origin-1123-backup refs/remotes/origin/main
   (
     cd "$fm_live" || exit 1
     paths=()
     for path in data state config .env .no-mistakes; do
       [ ! -e "$path" ] || paths+=("$path")
     done
     tar -czf "$fm_backup/home.tgz" "${paths[@]}"
     tar -tzf "$fm_backup/home.tgz" >"$fm_backup/archive-contents"
   )
   ```

   Create fresh tag names if these backups already exist. Check tracked-file cleanliness and the archive listing before continuing. Project clones stay in place and should contain no unlanded tasks.

4. Fetch only the upgrade branch and verify its full signed commit against the published delivery report. Check the listed live paths for tracked entries before switching.

   ```bash
   git -C "$fm_live" fetch origin refs/heads/upgrade/upstream-1123:refs/remotes/origin/upgrade/upstream-1123
   fm_new=$(git -C "$fm_live" rev-parse refs/remotes/origin/upgrade/upstream-1123)
   git -C "$fm_live" verify-commit "$fm_new"
   git -C "$fm_live" ls-tree -r --name-only "$fm_new" -- data state config projects .env .no-mistakes
   git -C "$fm_live" switch main
   git -C "$fm_live" reset --keep "$fm_new"
   ```

   The `ls-tree` command should print nothing. Run the last two commands only after the verification above. This changes local `main` in place.

5. Enable status archives with `touch "$fm_live/config/status-archive"` if desired. Leave `config/herdr-presentation-spaces` absent for automatic protocol-19 behavior. Save the old update-source setting if one exists, then set `config/self-update-source` to `origin upgrade/upstream-1123` for fast-forward updates on this release line. Upstream's [self-update source contract](../bin/fm-update.sh) also applies to subsequent releases.
6. Start a primary firstmate inside its Herdr workspace and run `bin/fm-session-start.sh`. Handle actionable bootstrap findings. Check the two direct-push registry forms, a disposable direct-push ship on an approved test origin, and an isolated Herdr projection and teardown. Verify that the landed commit is reachable from origin's default branch, the task pane and its resource manifest are gone, and AFK can report a test event. Use the named lab helper for any Herdr lifecycle experiment.

### Old records

- Herdr task metadata without `endpoint_task_id=` fails upstream's [endpoint identity check](configuration.md#teardown-identity-checks). Other backend-specific identity fields must also agree. Retire those tasks with the old code before switching. Never manufacture an endpoint binding from a pane label.
- Tasks without `spawn_gen=` can also be refused. Upstream's [teardown header](../bin/fm-teardown.sh) explains the narrow `--legacy-record` handling for dead or agent-less tasks; it still requires valid endpoint identity.
- Old `.resources` files predate the separate current-endpoint fields and compose-name hash. Use the old resource collector before switching. Retain the old state and matching code together if ownership needs later investigation.
- Keep old status archives as historical records. New archives use each task's own data directory.
- An existing `crew-dispatch.json` still requires an explicit resolved harness on spawn. Backlog format and existing registry entries remain compatible.

### Rollback

Freeze dispatch and safely land or reconcile upgraded tasks with the upgraded code first.
Stop the upgraded watcher, supervisor, and session.
Take a fresh backup of the post-upgrade records before returning local `main` to the rescue tag.

```bash
git -C "$fm_live" switch main
git -C "$fm_live" reset --keep fork-live-1123-backup
```

Inspect the pre-upgrade archive in a separate temporary directory.
Restore only the required old configuration or state paths after comparing them with the post-upgrade backup.
Keep later backlog and task records, and reconcile them before starting the old supervisor.
Verify the old code owns any endpoint still recorded before closing it.
Keep workspace cleanup scoped to the exact task and never stop the default Herdr server for migration or rollback.

## Refreshing from upstream

1. Fetch `kunchen/main` in an isolated checkout and branch from its new commit.
2. Diff the linked entry points above and compare each patch to upstream’s current behavior. Reapply only missing behavior against the new contracts.
3. Repeat the baseline and candidate checks with the same tool versions and named-lab constraints.
4. Publish a new upgrade branch and update the live home's configured update source after draining tasks. A rebased patch stack diverges from the old release branch, so use the cutover procedure for the new base. Reserve `/updatefirstmate` for fast-forwards on a single release line.

## Validation

The November 23 runs used separate disposable Git copies of pristine upstream `427056c4181c41074ad24f051f79919330df0fa5` and the upgrade code at `99963c4d1e3cdc8f43eccf9571c2399ef6bc5e81`.
Both copies used arm64 macOS 26.5.2, system Bash 3.2.57, Apple Git 2.50.1, system jq 1.7.1-apple, ShellCheck 0.11.0, and actionlint 1.7.12.
The validation environment used a temporary home and local Git fixture refs at the upstream commit.
Actionlint was installed inside the disposable checkout.
The complete lint and test runs ran serially with one worker and no test-script deadline.

```bash
CI=true FM_LINT_JOBS=1 bin/fm-lint.sh --jobs 1 --telemetry lint.tsv
FM_LIVE=0 env -u TMPDIR bin/fm-test-run.sh --all --jobs 1 --per-script-timeout-secs 0 --json tests.json
```

The test command scheduled every upstream family.
The two runs used the same capability gates, including 65 skips for `FM_LIVE=0` and 13 because the Herdr CLI was unavailable in the automated runner.
Herdr was left off the automated runner's PATH because upstream's real-Herdr suites can create and stop sessions outside the named lab contract.
A separate smoke test in the authorized named lab used Herdr 0.8.0 / protocol 19 and verified exact pane close, the ensuing structured `pane_not_found` result, guarded teardown, and the unchanged default session.

| Run | Pristine upstream | Upgrade |
| --- | --- | --- |
| Full lint | 607 roots, one failing root, exit 1. [Root results](fork-upgrade-1123-results/pristine-lint.roots.tsv) · [Tool output](fork-upgrade-1123-results/pristine-lint.out) · [Telemetry](fork-upgrade-1123-results/pristine-lint.tsv) | 614 roots, one failing root, exit 1. [Root results](fork-upgrade-1123-results/upgrade-lint.roots.tsv) · [Tool output](fork-upgrade-1123-results/upgrade-lint.out) · [Telemetry](fork-upgrade-1123-results/upgrade-lint.tsv) |
| Full tests | 340 scripts, 217 passes, 36 failures, 87 capability skips, exit 1. [Result file](fork-upgrade-1123-results/pristine-tests.json) | 341 scripts, 219 passes, 35 failures, 87 capability skips, exit 1. [Result file](fork-upgrade-1123-results/upgrade-tests.json) |

### Lint differences

Both final runs reported `SC2329` at `tests/fm-daemon.test.sh:1592` and `:1598` and `SC2031` at `:1617`, with byte-identical diagnostic output.
Actionlint validated all three workflows in both runs.
Seven new roots passed on the upgrade: `bin/fm-disk-lib.sh`, `bin/fm-resource-chrome.sh`, `bin/fm-resource-docker.sh`, `bin/fm-resource-gc.sh`, `bin/fm-resource-lib.sh`, `bin/fm-test-db-sweep-lib.sh`, and `tests/fm-resource.test.sh`.
The first full upgrade lint found `SC2329` on the local Docker wrapper because the cleanup helpers call it indirectly.
Commit `99963c4d` documents that call and suppresses the finding for that function.
The complete corrected run matched upstream on every shared root.

### Test differences and shared failures

The two full runs recorded 87 identical capability skips and no runner timeouts.
The earlier 600-second cutoff had interrupted long suites.
With the cutoff removed, both revisions passed the spawn-dispatch and remote secondmate lifecycle suites.
The first full verdicts differed in exactly four scripts.

| Script | Pristine upstream | Upgrade | Difference |
| --- | --- | --- | --- |
| `fm-documentation-audiences.test.sh` | Pass | Fail | The two new guides were missing from the upstream audience inventory. The final documentation registers both. See the final documentation check below. |
| `fm-pi-watch-extension.test.sh` | Fail | Pass | The first upstream run reported that actionable output did not wait for the predecessor to close. See the serial retry below. |
| `fm-resource.test.sh` | Absent | Pass | Adds 11 task-ownership and cleanup scenarios. |
| `fm-test-run.test.sh` | Fail | Pass | Pristine upstream rejected a modeled shard exactly at the packing budget. The upgrade packs a single complete inventory before applying the budget. See the serial retry below. |

All other per-script outcomes, family classifications, and skip reasons match.
The process-lock control-byte assertion in `fm-session-lock-ps-denied.test.sh` emitted different fixture PIDs and temporary paths for the same escaping mismatch.
Wall-clock timings are recorded in the result files.

These 34 scripts failed on both full runs with the same assertions.

| Script | First failure |
| --- | --- |
| `fm-afk-inject-e2e.test.sh` | The fake away-supervisor injection digest was misclassified. |
| `fm-afk-return.test.sh` | Failed evidence publication did not retain catch-up state. |
| `fm-backend-t3code.test.sh` | The refusal did not name the shell environment policy table. |
| `fm-bootstrap.test.sh` | Watcher hygiene probe returned 127. |
| `fm-calm-pi-extension.test.sh` | The simulated hung Chrome did not exhaust the expected retries. |
| `fm-composer-lib.test.sh` | The fake Herdr multiword Claude model returned `unknown` for an empty composer. |
| `fm-control-relaunch.test.sh` | Fake Herdr Pi relaunch did not complete registration. |
| `fm-control.test.sh` | The Hermes diagnostic omitted the gateway. |
| `fm-cortex-harness.test.sh` | The dialog fixture failed to exercise the identity gate. |
| `fm-cursor-harness.test.sh` | The harness detector missed a Cursor ancestor. |
| `fm-gotmp.test.sh` | Teardown returned nonzero with a valid task temp directory. |
| `fm-guard-stale-banner.test.sh` | A live tagged extension handoff printed a stale banner. |
| `fm-harness-precedence.test.sh` | Codex process ancestry failed to resolve the harness. |
| `fm-herdr-groups.test.sh` | The fake socket path used `/private/tmp` in place of `/tmp`. |
| `fm-hermes-harness.test.sh` | The NUL-argument fallback missed the harness identity. |
| `fm-kimi-harness.test.sh` | Hook installation refused the realistic config fixture. |
| `fm-live-lab-up-mate.test.sh` | The launch result omitted the mate readiness check. |
| `fm-live-lab.test.sh` | The mock primary window was reported stopped. |
| `fm-muse-harness.test.sh` | The process-name probe missed the Muse harness. |
| `fm-pr-merge.test.sh` | A well-formed Forgejo pull request URL failed the merge fixture. |
| `fm-public-followup.test.sh` | Outcome text reached 1,200 characters without truncation. |
| `fm-record-export-remote-home.test.sh` | The host had no `timeout` executable. |
| `fm-record-export.test.sh` | Archive retry accepted a committed manifest with an extra entry. |
| `fm-remote-job.test.sh` | An idle worker polled seven times in four seconds. |
| `fm-session-lock-ps-denied.test.sh` | The process providers disagreed on escaping tabs and newlines. |
| `fm-session-lock-windows-consumers.test.sh` | Watcher auto-arm failed to claim a Windows lock fixture. |
| `fm-spawn-orca-worktree.test.sh` | Failed deletion did not preserve the interactive `/bin/zsh` pane as expected. |
| `fm-startup-growth-check.test.sh` | The leading unsafe-memory finding was missing. |
| `fm-stow-guard.test.sh` | The fixture PATH still exposed `jq`. |
| `fm-supervision-host-park.test.sh` | A warm compact operated on a conversation that the next turn would not resume. |
| `fm-supervision-host.test.sh` | The stopped-host wake-queue check could not run because the host lacked the `timeout` executable. |
| `fm-voice-relay.test.sh` | The credential reuse assertion failed. |
| `fm-watch-arm.test.sh` | The restored row differed from the inherited row. |
| `fm-watch-wedge-cap-unconfigured-parity.test.sh` | System Bash 3.2 rejected the fixture's empty `cap_args` array before the busy-rung watcher could start. |

### Serial reruns

Seven scripts ran again on each revision, serially and without a runner cutoff. [Pristine results](fork-upgrade-1123-results/pristine-retry.json) · [Upgrade results](fork-upgrade-1123-results/upgrade-retry.json)

| Script | Pristine upstream rerun | Upgrade rerun |
| --- | --- | --- |
| `fm-calm-pi-extension.test.sh` | Same failure | Same failure |
| `fm-control-relaunch.test.sh` | Same failure | Same failure |
| `fm-pi-watch-extension.test.sh` | Passed | Passed |
| `fm-remote-job.test.sh` | Same failure | Same failure |
| `fm-supervision-host.test.sh` | Same missing `timeout` executable | Same missing `timeout` executable |
| `fm-test-run.test.sh` | Same exact-budget failure | Passed |
| `fm-watch-wedge-cap-unconfigured-parity.test.sh` | Same empty-array failure under system Bash | Same empty-array failure under system Bash |

The Pi watcher difference did not reproduce.
The runner packing difference reproduced on both attempts and the upgrade accepted the exact budget.
A worktree-local PATH entry used the already installed Bash 5.3.9 to rerun the watcher parity and simulated Chrome cases on both revisions.
Watcher parity passed on both.
The simulated Chrome case first failed on pristine upstream and passed on the upgrade, then passed on both in the next serial retry. [Pristine Bash 5.3 results](fork-upgrade-1123-results/pristine-bash53.json) · [Upgrade Bash 5.3 results](fork-upgrade-1123-results/upgrade-bash53.json) · [Pristine Chrome retry](fork-upgrade-1123-results/pristine-calm-retry.json) · [Upgrade Chrome retry](fork-upgrade-1123-results/upgrade-calm-retry.json)

The final delivery adds the documentation inventory correction and the result files to the tested upgrade commit.
The documentation audience and link check passed on those final files. [Final documentation result](fork-upgrade-1123-results/upgrade-final-docs.json)

### Focused upgrade checks

The direct-push tests verify both registry examples, the no-PR brief, `direct-push` and `yolo` spawn metadata, and teardown proof against the remote's advertised default branch.
The resource test exercises exact Docker labels, anonymous volumes, browser ownership, symlink refusal, dead-endpoint sweep, and the bootstrap project hook.
The coverage audit counted 340 scripts on upstream and 341 on the upgrade, with 297 and 298 portable serial scripts respectively and 16 real-Herdr scripts on each revision.
The upgrade's largest modeled serial shard is 1,198,710 ms against the 1,200,000 ms budget.
