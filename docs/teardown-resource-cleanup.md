# Task resource cleanup

This document owns the implementation boundary for task resource cleanup.
The measured 2026-08-13 incident is recorded in the local `data/learnings.md` entry for teardown resources.
This document is a code follow-up boundary, not an implementation of cleanup.

## Current gap

Task teardown does not yet collect team-owned database containers or Chrome processes.
Herdr task cleanup does not yet provide a complete ownership boundary for every surviving tab or home container.

## Required follow-up

The teardown implementation needs durable ownership metadata for every team-launched database container and Chrome process.
`fm-teardown.sh` must collect only resources that it can prove belong to the task or firstmate home.
Herdr cleanup must close task-owned tabs and remove empty task-owned containers without touching captain-owned or sibling-home resources.
Cleanup must be idempotent and fail closed when ownership cannot be proven.
The follow-up should be tracked as a code task and must not use broad process kills or unscoped multiplexer cleanup.
