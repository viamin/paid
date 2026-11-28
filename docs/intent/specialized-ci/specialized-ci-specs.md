---
parent: PAID
prefix: SPECIALIZED-CI
---

# Specialized CI specifications

- [x] **SPECIALIZED-CI-001** — When a trusted PR changes relevant runtime or job-specific inputs, lint SHALL select the affected API contract, migration, and performance jobs before those jobs allocate services or dependency setup; unrelated changes SHALL skip them without adding a detector runner.
- [x] **SPECIALIZED-CI-002** — When CI runs for a main-branch push, lint SHALL select all specialized jobs without requiring PR diff metadata.
- [x] **SPECIALIZED-CI-003** — When change detection inspects a PR, it SHALL consider the complete merge-base diff including deleted paths and both sides of renames, SHALL handle unusual filenames without command execution, and SHALL fail if the diff is unavailable.
- [x] **SPECIALIZED-CI-004** — When a specialized job is selected, CI SHALL preserve its existing author gate and execution; a failed lint dependency SHALL prevent expensive setup rather than report a passing specialized check.
