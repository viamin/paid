# Test Profiling

This repository uses `test-prof` for opt-in test profiling and `fixture_kit` for a small number of shared hotspot fixtures.

## Why `test-prof` first

`test-prof` gives us low-risk tools to measure factory churn and convert expensive setup incrementally.
It works with the current `RSpec` + `FactoryBot` setup and does not require a fixture rewrite.

We are using `fixture_kit` selectively for a few large activity specs under `spec/fixture_kit/`, but only where the setup graph is stable and heavily reused. Most of the suite still relies on ad hoc `FactoryBot.create(...)` setup, so `test-prof` remains the safer first tool for finding wins.

## Local usage

Profile the regular non-system suite's factory usage:

```bash
FPROF=1 COVERAGE=false bin/rspec --exclude-pattern "spec/performance/**/*_spec.rb,spec/system/**/*_spec.rb"
```

Find examples that write to the database unnecessarily:

```bash
FDOC=1 COVERAGE=false bin/rspec --exclude-pattern "spec/performance/**/*_spec.rb,spec/system/**/*_spec.rb"
```

The most common follow-up optimizations are:

- Replace `create(...)` with `build(...)` or `build_stubbed(...)` when persistence is not required.
- Use `create_default(...)` selectively to reduce factory cascades in deeply-associated factories.
- Promote very stable, heavily reused persisted graphs into `fixture_kit` definitions under `spec/fixture_kit/`.

## Tenant isolation note

Avoid `let_it_be` in this app unless the spec explicitly handles tenant context. In Paid, `let_it_be` setup runs in `before(:context)`, which bypasses the usual per-example `TenantContext.with_system_access` wrapper and can trigger row-level-security failures.

## CI usage

Use the `Test Prof` GitHub Actions workflow (`workflow_dispatch`) to generate profiling output on a GitHub runner without slowing the default PR checks.
