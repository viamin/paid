---
parent: PAID
prefix: SPECIALIZED-CI
---

# Specialized CI scheduling

The existing lint job classifies the complete PR diff before dependency setup.
It uses a NUL-delimited, rename-disabled Git diff against the merge base, so both
sides of renames and deleted paths participate. An unavailable diff fails lint;
unknown coverage never becomes an unrelated-change result. Pushes to main select
all specialized checks without needing a PR diff.

Pact verification, Schemathesis, migration replay, and performance benchmarks
depend on successful lint and their change output. Existing trusted-author gates,
services, test commands, and failure reporting remain intact. No detector runner
is added. A lint failure stops dependent setup and remains a failing CI check.

## Included inputs

- Config, libraries, database files, Ruby/JavaScript dependencies, toolchain pins,
  executable scripts, and the CI workflow select every specialized check.
- Application files select API contracts and performance benchmarks. Migration
  replay is selected by database or shared runtime inputs; an application-only
  change introduces no migration to replay.
- API schemas/Pacts and Schemathesis constraints select API contracts.
- Benchmark scripts, performance specs, and baseline documents select performance.
- Documentation outside those input directories and unrelated specs select none.

These conservative runtime groups avoid maintaining a call graph in YAML. They
can select more work than necessary, but do not narrow runtime dependencies to
API controllers alone. Full main-branch checks remain the integration backstop.
