---
parent: PAID
prefix: SCREENSHOT-CI
---

# Screenshot CI

## Purpose

PR screenshot automation supplies browser review evidence while avoiding expensive
runner setup for changes outside the UI.

## Workflow boundaries

The capture workflow filters pull-request events by Rails UI paths, including the
UI detector's explicit exclusions. Its detection job remains a second check.
Closed-PR storage cleanup remains unfiltered. The repository must not require
checks from this path-filtered workflow for every PR.

Publishing remains unfiltered so a PR that removes its UI changes can mark an
existing screenshot comment stale. A read-only resolver checks all pages of the
PR file list using the trusted base revision's UI detector before polling capture.
For a non-UI PR, it checks all comment pages: an existing screenshot marker on a
synchronize event requires a stale update; otherwise publishing is skipped.
Only actionable resolver outcomes allocate the publishing runner, PostgreSQL,
and Rails/JavaScript dependency setup. API errors preserve the existing visible
capture-failure outcome instead of silently skipping evidence.

## Trust and limits

The resolver and publisher retain the same author and same-repository gates.
Both check out the immutable base SHA; PR code never receives publishing secrets.
GitHub's native path-filter diff limits apply. Inclusion paths must cover the
Rails detector; tests compare their behavior for representative paths.
