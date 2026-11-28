---
parent: SCREENSHOT-CI
---

# Screenshot CI specifications

- [x] **SCREENSHOT-CI-001**: When a PR has no UI-facing paths, the capture workflow shall filter out its pull-request event while leaving closed-PR cleanup unfiltered.
- [x] **SCREENSHOT-CI-002**: When a non-UI PR has no screenshot comment, the resolver shall skip publishing without polling capture runs or starting the publishing job.
- [x] **SCREENSHOT-CI-003**: When a synchronize event removes all UI changes and an existing screenshot comment is present, the resolver shall request a stale-comment update without polling capture runs.
- [x] **SCREENSHOT-CI-004**: When the resolver skips publishing, the workflow shall allocate no PostgreSQL service or Rails dependency setup for publishing.
- [x] **SCREENSHOT-CI-005**: When checking UI changes and existing screenshot comments, the resolver shall inspect all API pages and preserve capture-failure reporting on API errors.
