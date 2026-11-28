---
parent: PAID
prefix: MUTATION-CI
---

# Mutation test CI

Incremental PR mutation runs use native workflow path filters before allocating
PostgreSQL or installing Ruby dependencies. Included paths cover configured subject
files, their specs, shared test setup, factories and fixtures, application config,
libraries, database inputs, dependency/toolchain pins, mutation config, the RSpec
runner, and the workflow. Tests enforce the subject-class inventory from
`.mutant.yml` so adding a class requires reviewing the filter.

The daily full mutation run remains unfiltered. Incremental execution still uses
Mutant's diff selection; changing dependencies or tests alone can select no changed
subjects. This filter does not introduce full mutation coverage for those PRs.
The workflow must not be a required check on every PR. Native diff limits apply.
