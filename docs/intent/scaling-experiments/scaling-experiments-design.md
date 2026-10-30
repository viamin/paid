---
parent: PAID
prefix: SCALING-EXPERIMENTS
---

# Low-Level Design: Scaling Experiment Reporting

> Companion to [`docs/high-level-design.md`](../../high-level-design.md) and
> [RDR-017](../../rdrs/RDR-017-orchestration-scaling-laws.md). This segment
> owns the user-facing scaling-experiment dashboard and persisted analysis
> report language.

## Purpose

Scaling experiments help operators understand whether changes to agent count,
iterations, or parallelism affect outcomes. Their dashboard and exported
summaries must communicate the available evidence and analytical limits in
plain language, without exposing internal decision-record terminology.

## Reporting contract

Each experiment reports its configured sample floor and whether it meets the
30-sample-per-value target. An experiment below that target remains valid for
observation, but the dashboard clearly identifies the reduced evidence rather
than implying the analysis is conclusive.

Reports describe the actual method: Wilson confidence intervals for rates,
normal-approximation confidence intervals for means, and a log-log linear fit
for scaling exponents. They also state that the fit does not compare
power-law, logarithmic, and linear regression models. This lets operators
interpret the results without needing project-internal context.

Previously persisted report notes are translated at the dashboard boundary so
historical summaries follow the same presentation contract.

## Compatibility

Existing serialized keys, including `meets_rdr_target` and
`rdr_target_min_samples_per_value`, remain stable because downstream consumers
may rely on them. They are machine-readable contract fields, not labels or
report prose.

## References

- `app/views/projects/scaling_dashboards/show.html.erb`
- `app/services/scaling_experiments/summarize_results.rb`
- `app/services/scaling_experiments/analyze_scaling_law.rb`
