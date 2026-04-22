# Performance Benchmarks

Paid tracks four repeatable performance metrics for release and scaling work:

| Metric | Source | Default Budget |
| --- | --- | ---: |
| Container startup time | Recent completed `provision_container` phases | 30 seconds p95 |
| Workflow latency | Recent finished `AgentRun` wall-clock duration | 60 minutes p95 |
| Dashboard load time | Service calls used by `DashboardController#show` | 1 second p95 |
| Search latency | `Knowledge::Search` exact mode using an indexed artifact identifier | 500 ms p95 |

Run the suite from a prepared Rails environment:

```bash
RAILS_ENV=production scripts/performance/benchmark.rb \
  --output tmp/performance/report.json \
  --markdown tmp/performance/report.md
```

For local smoke checks, use development data:

```bash
RAILS_ENV=development scripts/performance/benchmark.rb
```

Metrics that need data skip themselves instead of fabricating measurements. A fresh database usually skips container startup, workflow latency, and search latency until agent runs and knowledge artifacts exist.

## Regression Checks

Compare a fresh report to the checked-in baseline budgets:

```bash
scripts/performance/benchmark.rb \
  --baseline docs/performance/baseline.json \
  --fail-on-regression
```

The checked-in baseline is budget-oriented because machine-specific timings vary significantly between developer laptops, containers, and CI. When benchmarking a stable staging environment, keep an environment-specific historical baseline outside the repo and pass it with `--baseline`.

## CI

The CI performance job is gated by the repository variable `PAID_PERFORMANCE_BENCHMARKS=true`. It is disabled by default so normal pull requests do not fail on noisy shared-runner timings. Enable it for scheduled or manually selected benchmarking runs.

## Tuning Notes

- Container startup: keep the `paid-agent` image warm, avoid adding large package installs to runtime startup, and watch `provision_container` phase p95 before changing Docker image layers.
- Workflow latency: inspect phase breakdowns before scaling workers; queue latency and `run_agent` duration usually need different fixes.
- Dashboard load: prefer bounded queries, aggregate in SQL, and keep live widgets on narrow service calls instead of loading full records.
- Search latency: use exact mode for identifier lookups, keep knowledge artifact indexes current, and only enable semantic or hybrid benchmarks when the embedding provider and Qdrant environment are stable.
