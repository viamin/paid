# Test Profiling

This repository uses `test-prof` for opt-in test profiling and `fixture_kit` for a small number of shared hotspot fixtures.

## Why `test-prof` first

`test-prof` gives us low-risk tools to measure factory churn and convert expensive setup incrementally.
It works with the current `RSpec` + `FactoryBot` setup and does not require a fixture rewrite.

We are using `fixture_kit` selectively for a few large activity specs under `spec/fixture_kit/`, but only where the setup graph is stable and heavily reused. Most of the suite still relies on ad hoc `FactoryBot.create(...)` setup, so `test-prof` remains the safer first tool for finding wins.

## Local usage

Generate the hotspot map used in the May 2026 deep-dive audit:

```bash
bin/test-prof-audit hotspot-map
```

Run the deeper request-spec audit passes in one shot:

```bash
bin/test-prof-audit requests-deep
```

Compare runtime by RSpec metadata type across the broader suite:

```bash
bin/test-prof-audit type-breakdown
```

Run the core profiling passes for one hotspot file:

```bash
bin/test-prof-audit file spec/requests/github_tokens_spec.rb
```

Profile the regular non-system suite's factory usage:

```bash
FPROF=1 COVERAGE=false bin/rspec --exclude-pattern "spec/performance/**/*_spec.rb,spec/system/**/*_spec.rb"
```

Find examples that write to the database unnecessarily:

```bash
FDOC=1 COVERAGE=false bin/rspec --exclude-pattern "spec/performance/**/*_spec.rb,spec/system/**/*_spec.rb"
```

Profile SQL-heavy examples:

```bash
EVENT_PROF=sql.active_record EVENT_PROF_EXAMPLES=1 COVERAGE=false bin/rspec spec/requests/github_tokens_spec.rb
```

Profile setup-heavy examples:

```bash
RD_PROF=1 COVERAGE=false bin/rspec spec/requests/github_tokens_spec.rb
```

Compare the shape of large example groups:

```bash
TPS_PROF=10 COVERAGE=false bin/rspec spec/requests --exclude-pattern "spec/performance/**/*_spec.rb,spec/system/**/*_spec.rb"
```

Compare runtime by RSpec metadata type:

```bash
TAG_PROF=type COVERAGE=false bin/rspec spec --exclude-pattern "spec/performance/**/*_spec.rb,spec/system/**/*_spec.rb"
```

The most common follow-up optimizations are:

- Replace `create(...)` with `build(...)` or `build_stubbed(...)` when persistence is not required.
- Use `create_default(...)` selectively to reduce factory cascades in deeply-associated factories.
- Collapse repeated factory graphs by reusing already-created account/user/project fixtures inside a spec when creator fields are not part of the assertion.
- Promote very stable, heavily reused persisted graphs into `fixture_kit` definitions under `spec/fixture_kit/` only when the profiling data shows that the extra risk is justified.

## Deep-Dive Findings

The one-time May 2026 audit, including before/after results for `spec/requests/github_tokens_spec.rb`
and `spec/requests/agent_runs_spec.rb`, is documented in
[`docs/TEST_PROF_AUDIT_2026-05.md`](./TEST_PROF_AUDIT_2026-05.md).

## Tenant isolation note

Avoid `let_it_be` in this app unless the spec explicitly handles tenant context. In Paid, `let_it_be` setup runs in `before(:context)`, which bypasses the usual per-example `TenantContext.with_system_access` wrapper and can trigger row-level-security failures.

## CI usage

Use the `Test Prof` GitHub Actions workflow (`workflow_dispatch`) to generate profiling output on a GitHub runner without slowing the default PR checks.
