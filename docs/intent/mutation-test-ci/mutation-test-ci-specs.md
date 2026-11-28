---
parent: PAID
prefix: MUTATION-CI
---

# Mutation test CI specifications

- [x] **MUTATION-CI-001** — When a PR changes neither a configured mutation subject nor included test, runtime, dependency, or workflow inputs, GitHub SHALL filter the incremental mutation workflow before allocating a runner.
- [x] **MUTATION-CI-002** — When the daily full mutation schedule fires, CI SHALL retain the existing full mutation run without a path filter.
- [x] **MUTATION-CI-003** — When the configured mutation subject classes change, regression checks SHALL require reviewing their workflow path coverage.
