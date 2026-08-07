# RDR-016 / RDR-017 Audit Report — 2026-08-04

## Summary

The 2026-08-04 RDR gap audit flagged RDR-016 and RDR-017 as "Implemented" while
their implementation-status sections still named follow-up gaps. This report
classifies those named gaps as blockers, enhancement work, or explicitly
non-blocking future research, and updates the RDR wording so "Implemented" no
longer conflicts with the named gaps.

Closeout issue: [#3174](https://github.com/viamin/paid/issues/3174).

## RDR-016: Self-Improving Agent Coordination

### Named gap (as written before this audit)

> "Scheduled coordination policy evolution and experiment-to-policy promotion are
> not yet wired as production automation."

### Classification: not a gap — the wording was stale; remaining item is an intentional design decision

Verification against the codebase shows the named gap is inaccurate:

- **Scheduled coordination policy evolution IS wired as production automation.**
  `CoordinationPolicyEvolutionJob` runs on a weekly cron
  (`config/initializers/good_job.rb`, `coordination_policy_evolution` entry) and
  drives `Workflows::CoordinationPolicyEvolutionWorkflow` via Temporal. The
  workflow analyzes decision patterns, generates candidate policy versions, and
  persists draft `CoordinationPolicyVersion` records.
- **Scheduled experiment resolution and winner selection ARE wired.**
  `CoordinationExperimentResolutionJob` runs every four hours
  (`config/initializers/good_job.rb`, `coordination_experiment_resolution`
  entry), evaluates running experiments for promotion readiness via
  `CoordinationExperiments::PromotionReadiness`, and records the winning variant
  (highest `avg_coordination_score` passing all guardrails).

The only step that is **not** automated is promoting a winning experiment
variant to the *active* `CoordinationPolicyVersion`. This is a deliberate
safety gate, not a missing capability: candidate versions are created with
`approval_state: {required: true, status: "pending_review", auto_promote: false}`
(in `CoordinationPolicyEvolution::CreateCandidates`), and an operator activates
the chosen version via `CoordinationPolicy#activate_version!`. Both jobs'
header comments document this as intentional.

### Shipped evidence

- Policy/version models: `app/models/coordination_policy.rb`,
  `app/models/coordination_policy_version.rb`.
- Experiments: `app/models/coordination_experiment.rb` (+ variant/assignment).
- Decision logging: `app/models/orchestration_decision.rb`,
  `app/models/decomposition_decision.rb`, with active call sites in
  `app/services/coordination/failure_recovery.rb`,
  `app/services/coordination/escalation_service.rb`, and Temporal activities.
- Scheduled automation: `config/initializers/good_job.rb` (cron entries),
  `app/jobs/coordination_policy_evolution_job.rb`,
  `app/jobs/coordination_experiment_resolution_job.rb`,
  `app/temporal/workflows/coordination_policy_evolution_workflow.rb`,
  `app/services/coordination_experiments/promotion_readiness.rb`.

### Conclusion

RDR-016 remains **Implemented**. No follow-up production work is desired: the
human-review promotion gate is by design. The implementation-status wording was
corrected to accurately describe the wired automation and to record the
promotion gate as an intentional safety decision.

## RDR-017: Orchestration Scaling Laws

### Named gap (as written before this audit)

> "statistical ambition: Paid currently uses descriptive confidence intervals,
> log-log slope intervals, and explicit threshold reporting rather than the full
> comparative regression suite originally proposed."

### Classification: explicitly non-blocking future research (not a blocker, not desired production work)

The implementation-status wording is accurate. The descriptive statistics are
shipped and sufficient; the full comparative regression suite (power-law /
logarithmic / linear fits with R²-based model selection, context-segmented
comparison, and exponent-weighted Lagrangian allocation) was never built.

This is classified as non-blocking future research, not enhancement work:

- RDR-017 is a **Type: Research, Priority: Low** record. Its goal is to
  discover scaling behavior and inform allocation — which the descriptive
  confidence intervals and log-log slope analysis achieve.
- The shipped code consciously documents the simplification in place
  (`ScalingExperiments::AnalyzeScalingLaw#statistical_rigor`,
  `SummarizeResults#simplifications`) and the dashboard surfaces an
  "Intentional Simplifications" banner and below-threshold badges.
- No production capability depends on the comparative regression suite.

### Shipped evidence

- Models: `app/models/scaling_observation.rb`,
  `app/models/scaling_experiment.rb`,
  `app/models/scaling_experiment_assignment.rb`.
- Statistics: `app/services/scaling_experiments/statistics.rb` (Wilson +
  normal-approximation intervals, log-log slope intervals),
  `summarize_results.rb`, `analyze_scaling_law.rb`.
- Dynamic allocation: `app/services/scaling/resource_allocator.rb`.
- Orchestration integration:
  `app/temporal/activities/resolve_scaling_experiment_activity.rb`,
  `app/temporal/workflows/feature_orchestration_workflow.rb`.
- Dashboard: `app/views/projects/scaling_dashboards/show.html.erb`,
  `app/services/projects/scaling_dashboard_stats.rb`.

### Conclusion

RDR-017 remains **Implemented**. The comparative regression suite is explicitly
deferred non-blocking future research for a Low-priority Research RDR. No
follow-up production issue is required. The implementation-status wording was
updated to separate the shipped acceptance scope from the deferred research and
to classify the gap explicitly.

## Cross-cutting outcome

| RDR | Named gap | Classification | Follow-up issue? |
|-----|-----------|----------------|------------------|
| RDR-016 | Scheduled evolution / promotion "not wired" | Stale wording — automation is wired; promotion is an intentional human-review gate | No (by design) |
| RDR-017 | Comparative regression suite absent | Non-blocking future research | No (Low-priority Research RDR) |

Both RDRs now clearly distinguish shipped acceptance scope from optional future
work, and no desired production work remains untracked.
