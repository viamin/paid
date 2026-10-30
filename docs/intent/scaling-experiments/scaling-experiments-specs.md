# EARS Specs: Scaling Experiment Reporting

> Testable claims for user-facing scaling experiment reporting. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **SCALING-EXPERIMENTS-001** — When a scaling experiment is displayed,
  the system SHALL identify the 30-sample target and explain when an
  experiment is configured below it without presenting Paid-owned RDR
  terminology.
  *Code:* `projects/scaling_dashboards/show`.
  *Test:* `spec/requests/projects/scaling_dashboards_spec.rb`.

- [x] **SCALING-EXPERIMENTS-002** — When a scaling analysis report is
  generated, the system SHALL describe its confidence-interval and log-log
  linear-fit limitations in user language without changing its 30-sample
  threshold or existing machine-readable threshold keys; when a previously
  persisted report is displayed, the system SHALL present equivalent
  user-language notes.
  *Code:* `ScalingExperiments::SummarizeResults`,
  `ScalingExperiments::AnalyzeScalingLaw`.
  *Test:* `spec/services/scaling_experiments/summarize_results_spec.rb`,
  `spec/services/scaling_experiments/analyze_scaling_law_spec.rb`.
