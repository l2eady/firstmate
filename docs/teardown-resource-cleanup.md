# Task resource cleanup

This document owns the implementation boundary for task resource ownership and cleanup.
The measured 2026-08-13 incident is recorded in the local `data/learnings.md` entry for teardown resources.
The durable manifest is written before the agent launch, so cleanup does not depend on the agent surviving.

## Ownership contract

Each task gets a deterministic owner value of `firstmate:<home-tag>:<task-id>`.
The home tag includes the resolved firstmate root hash and distinguishes secondmate homes.
The manifest lives at `state/<task-id>.resources` and records the owner, task, home, root, backend endpoint, temporary root, Docker project, and browser profile.
The task temporary root and browser profile each contain a regular-file `.fm-resource-owner` marker with the same owner and task id.
If the conventional temporary-root name is occupied by another marker or unsafe path, spawn uses a home-scoped suffix and preserves the existing entry.
The manifest and markers are written before the task endpoint receives its first command.
The task environment exports the owner metadata and puts task-owned Docker and Chrome wrappers first in `PATH`.
The wrappers derive the task identity from their installed task root and validate the durable manifest before forwarding a resource command.

Tasks spawned by the supported lifecycle before resource manifests and markers were introduced recorded only `tasktmp=` and created the exact `/tmp/fm-<id>/gotmp` shape.
Teardown has a narrow compatibility proof for that legacy shape: it is enabled only when the current metadata has no resource manifest, the recorded endpoint was live with the task's expected target before the scoped kill and is gone afterward, the root is the canonical `/tmp/fm-<id>` directory recorded for the task, it has a real `gotmp` child, and no modern marker exists.
If the endpoint is absent or cannot be proven live and gone, cleanup preserves the untagged root and metadata.
All other untagged roots remain preserved.

## Docker resources

The wrapper's real-executable selection, including bare command names, is documented in the header of `bin/fm-resource-docker.sh`.
Direct Docker container, service, network, and volume creation through the task wrapper receives exact `com.firstmate.owner`, `com.firstmate.task`, `com.firstmate.home`, backend, and endpoint labels.
Docker Compose receives an exact generated `COMPOSE_PROJECT_NAME` containing the home tag and task id, which is the ownership marker for Compose-created resources.
Teardown queries exact owner and Compose-project labels, re-inspects every candidate, and removes a resource only when the inspected labels still match the task owner or exact generated project.
The wrapper records Docker use in a sidecar so teardown fails when Docker is required but unavailable instead of pretending cleanup succeeded.
Resources with missing, malformed, or mismatched labels are preserved and leave the manifest in place for diagnosis.

## Chrome resources

The task wrapper assigns a deterministic `CHROME_DEVTOOLS_AXI_SESSION` as the browser ownership label and a task-owned user-data profile.
The profile has the same regular-file owner marker as the task temporary root.
Teardown stops the recorded session only when the task actually used the task-owned Chrome wrapper, then removes the verified profile.
An explicitly supplied browser URL, auto-connect mode, or user-data directory disables browser ownership and prevents teardown from stopping that browser.

## Teardown and orphan collection

`bin/fm-teardown.sh` cleans the exact manifest resources after it has killed the recorded backend endpoint and before it removes task metadata.
Cleanup failure preserves the manifest and reports an error, so a later run can retry instead of losing the ownership record.
`bin/fm-resource-gc.sh --dry-run` lists manifests eligible for orphan cleanup without deleting anything.
`bin/fm-resource-gc.sh` validates the manifest owner against the recorded home and root before it acts.
The garbage collector requires a recorded backend endpoint and a confident dead-owner result from the backend liveness probe.
After that proof, the collector removes the exact recorded backend endpoint before removing task-owned Docker, browser, profile, and temporary-root resources.
Live and unknown owners are preserved, including when a backend cannot be queried reliably.
The collector scans durable manifests rather than broad Docker, process, browser, or multiplexer patterns.
No command removes a resource when firstmate cannot prove that the resource belongs to the task.
Backend endpoint teardown remains scoped to the exact target recorded in task metadata, so captain-owned and sibling-home endpoints are not selected by a pattern.

## CI state classification

The no-mistakes CLI owns its existing CI step, but firstmate owns the current-state interpretation because no-mistakes is not the repository being changed here.
When the CI log says that no checks were reported, `bin/fm-crew-state.sh` queries `gh-axi pr checks` for the recorded pull request.
The first no-check result is rechecked after `FM_CI_NO_CHECKS_GRACE_SECS`, defaulting to three seconds, to avoid treating a transient GitHub outage as absent CI.
Only two confirmed no-check results produce `state: no-ci` with `no CI checks available` detail.
GitHub-reported passing checks produce `checks green`, and failures, pending checks, API errors, or ambiguous output remain non-terminal working states.
No-CI, green CI, and failed CI therefore remain distinct in current-state output and status-log guidance.
