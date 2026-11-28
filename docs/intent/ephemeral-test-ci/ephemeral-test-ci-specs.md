---
parent: PAID
prefix: EPHEMERAL-CI
---

# Ephemeral test CI specifications

- [x] **EPHEMERAL-CI-001** — When a PR diff contains no ephemeral test paths or workflow change, GitHub SHALL filter its ephemeral workflow event before allocating a runner; matching paths SHALL include added, modified, and deleted tests.
- [x] **EPHEMERAL-CI-002** — When the ephemeral workflow posts a result comment, it SHALL identify the tested PR head revision and workflow run.
