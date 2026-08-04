# RDR-035 Audit Report — 2026-08-04

## Summary

RDR-035 is no longer accurately described as `Accepted` or unimplemented. As of Tuesday, August 4, 2026, the repository ships the style-guide evolution pipeline the RDR called for: immutable style-guide versions, style-guide-specific A/B tests, runtime exposure tracking, Temporal-driven evolution, and quality-score attribution back to assigned variants.

The closeout issue for this audit is [#3168](https://github.com/viamin/paid/issues/3168). The audit found no remaining implementation gap large enough to justify leaving RDR-035 open or downgrading it to `Partially Implemented`.

## Reconciliation Against the Accepted Scope

| Accepted scope item | Status | Evidence |
|---|---|---|
| Style-guide versioning | **Shipped** | `db/migrate/20260709225313_create_style_guide_evolution_pipeline.rb`, `db/schema.rb`, `app/models/style_guide_version.rb` |
| Style-guide A/B test tables and lifecycle | **Shipped** | `app/models/style_guide_ab_test.rb`, `app/models/style_guide_ab_test_variant.rb`, `app/models/style_guide_ab_test_assignment.rb` |
| Exposure tracking per run | **Shipped** | `app/models/style_guide_run_exposure.rb`, `app/services/style_guides/inject_into_prompt.rb`, `spec/services/style_guides/inject_into_prompt_spec.rb` |
| Evolution workflow | **Shipped** | `app/jobs/style_guide_evolution_job.rb`, `app/temporal/workflows/style_guide_evolution_workflow.rb`, `app/temporal/activities/{sample_style_guide_runs,generate_style_guide_mutations,create_style_guide_variants,create_style_guide_ab_test}_activity.rb` |
| Quality attribution and winner promotion | **Shipped** | `app/services/style_guide_ab_tests/{assign,analyze,record_result,promote_winner}.rb`, `spec/services/style_guide_ab_tests/{analyze,record_result,promote_winner}_spec.rb` |

## What Shipped

### Versioned style-guide storage

- Migration `db/migrate/20260709225313_create_style_guide_evolution_pipeline.rb` added:
  - `style_guide_versions`
  - `style_guide_ab_tests`
  - `style_guide_ab_test_variants`
  - `style_guide_ab_test_assignments`
  - `style_guide_run_exposures`
  - `style_guides.current_version_id`
- `db/schema.rb` confirms those tables and foreign keys are present in the live schema.
- `app/models/style_guide_version.rb` enforces immutable version content, parent lineage constraints, review-state validation, and prompt-content rendering.

### Runtime assignment and exposure recording

- `app/services/style_guides/inject_into_prompt.rb` resolves the effective guide version for each applicable guide.
- When an `AgentRun` is present, the service:
  - reuses an existing style-guide A/B assignment when one exists
  - enrolls the run in a running style-guide A/B test when needed
  - records `StyleGuideRunExposure` rows including version, scope, position, injected source, and linked assignment
- `spec/services/style_guides/inject_into_prompt_spec.rb` covers both baseline exposure recording and assigned variant injection.

### Evolution pipeline

- `app/services/style_guide_evolution/sample_runs.rb` samples recent `StyleGuideRunExposure` rows joined to automated `QualityMetric` records and flags underperforming current versions as mutation candidates.
- `app/services/style_guide_evolution/mutate.rb` uses `AgentHarness.send_message` to generate full-guide mutations with bounded count and output-size filtering.
- `app/services/style_guide_evolution/create_variants.rb` persists evolved versions with lineage and idempotency support.
- `app/jobs/style_guide_evolution_job.rb` discovers eligible non-global guides and starts one Temporal workflow per guide.
- `app/temporal/workflows/style_guide_evolution_workflow.rb` orchestrates sample → mutate → create variants → create A/B test.

### Quality attribution and promotion

- `app/services/style_guide_ab_tests/record_result.rb` records per-run quality scores on assignments, updates aggregate variant statistics, clears stale cached analysis when needed, and auto-completes tests once sampling thresholds are met.
- `app/services/style_guide_ab_tests/analyze.rb` performs the control-vs-variant comparison and chooses the winning arm when confidence thresholds are satisfied.
- `app/services/style_guide_ab_tests/promote_winner.rb` promotes the winning version to `style_guides.current_version_id`, mirrors the raw content back onto the mutable `style_guides` row, and enqueues recompression.
- `spec/services/style_guide_ab_tests/record_result_spec.rb` and `spec/services/style_guide_ab_tests/promote_winner_spec.rb` cover the attribution and promotion path.

## Minor Implementation Divergence

The RDR's implementation plan named separate `StyleGuides::RecordRunExposures`, `StyleGuides::BuildInjectedGuideSet`, and `StyleGuides::RenderContentForPrompt` services. The shipped implementation keeps those behaviors inside `StyleGuides::InjectIntoPrompt`.

This is a packaging difference, not a scope gap:

- assigned-arm injection is present
- exposure recording is present
- prompt-content selection and truncation are present

No follow-up issue is needed for that consolidation alone.

## Conclusion

RDR-035 should now be treated as **Implemented**:

- The repository contains the schema, model, service, workflow, and test surface needed for style-guide versioning, A/B testing, exposure tracking, evolution, and quality attribution.
- The prior `Accepted but not implemented` status was stale as of Tuesday, August 4, 2026.
- No additional implementation-chain issue is required to keep the RDR from being stuck in `Accepted`.
