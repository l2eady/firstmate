# Task resource cleanup

`bin/fm-spawn.sh` writes an ownership manifest at `state/<id>.resources` before the worker launch when a task has Docker or Chrome tooling available.
The manifest binds the task to a physical home and source root, a private task temp directory, and the current runtime endpoint.
The Docker labels retain their original endpoint identity across a relaunch so the new worker and cleanup can both find the same resources.
Task and Chrome profile directories have separate regular-file ownership markers.
An occupied conventional temp path with a foreign or missing marker makes a fresh spawn choose a home-scoped suffix.

The Docker wrapper labels supported container, service, network, and volume creation.
Compose uses an exact task-specific project name, including a hash of the original task ID to distinguish IDs that Compose would normalize identically.
Cleanup queries the exact labels, inspects each candidate again, and requires either the complete direct labels or the generated Compose project without conflicting Firstmate labels.
Container removal includes anonymous volumes through `docker rm -f -v`.
The wrapper supports the task's ordinary Docker context.
Keep the same Docker context through cleanup, and manage resources created by direct binaries or deliberately separate Docker contexts through the tooling that created them.

The Chrome wrapper records use of the task's own named session and profile.
Explicit browser URLs, profiles, auto-connect, and session overrides stay outside that lease.
Cleanup uses the exact recorded session and verifies the profile marker separately before stopping the browser or removing its profile.

Ordinary teardown stops the recorded worker through its usual backend path and retires resources before deleting the ownership record.
A failed removal keeps the manifest available for retry.
`bin/fm-resource-gc.sh --dry-run` reports candidates without modifying them.
Bootstrap uses the same sweep during its local mutating phase.
The collector uses exact tmux inventory or structured Herdr presence and preserves live or ambiguous targets.
It may close an exact tmux shell when the task record matches and the agent liveness probe confirms death.
A present Herdr pane remains with ordinary teardown so the presentation lock and focus restoration still apply.
Other backends use ordinary teardown for resource cleanup.
Legacy untagged temp directories are eligible only at the canonical `/tmp/fm-<id>` path with a real `gotmp` child, no modern marker, and a recorded endpoint proved live before the scoped close.

Projects that implement executable `scripts/e2e_db_cleanup.sh` own test database cleanup through its `--orphans` contract.
Bootstrap calls it from configured project clones and teardown calls it from the stopped task copy while the script still exists.
The project is responsible for distinguishing live and abandoned lanes.
The default timeout is 45 seconds per project, configurable through `FM_TEST_DB_SWEEP_TIMEOUT`.
The hook is advisory and teardown continues on a missing script, failure or timeout.

Bootstrap and the watcher report low space on the home filesystem below `FM_DISK_WARN_GB` (default 50 decimal GB).
The watcher probes every `FM_DISK_CHECK_INTERVAL` seconds (default 300) and wakes once per low-space episode while tasks are recorded.
