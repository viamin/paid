# RDR-038 Audit Report — 2026-08-04

## Summary

RDR-038 is no longer accurately described as partially implemented because of an
open phase-2 sync gap. As of Tuesday, August 4, 2026, the repository ships the
full OpenRouter free-model catalog and runner flow the RDR describes:
free-model data-model fields, daily OpenRouter sync, deterministic
classification, quality-bar marking, the `openrouter_free` runner, default tier
selection that avoids weak models, rate-limit rotation, project data
classification routing, and the catalog UI.

The closeout issue for this audit is
[#3170](https://github.com/viamin/paid/issues/3170). The reconciliation against
the RDR's stale implementation-status note and closed phase chain found that the
specific gap still called out in the RDR — OpenRouter model
sync/classification/quality filtering from [#2380](https://github.com/viamin/paid/issues/2380)
— has shipped and is covered by code plus tests.

## GitHub State

- Tracking issue [#2378](https://github.com/viamin/paid/issues/2378) is closed.
- Phase issues [#2381](https://github.com/viamin/paid/issues/2381),
  [#2380](https://github.com/viamin/paid/issues/2380),
  [#2379](https://github.com/viamin/paid/issues/2379),
  [#2383](https://github.com/viamin/paid/issues/2383),
  [#2382](https://github.com/viamin/paid/issues/2382),
  [#2384](https://github.com/viamin/paid/issues/2384), and
  [#2385](https://github.com/viamin/paid/issues/2385) are closed.
- Closeout audit issue [#3170](https://github.com/viamin/paid/issues/3170) is
  open.

## Reconciliation: the stale phase-2 gap vs. the code

| Requirement still listed as missing in RDR-038 | Status | Evidence |
|---|---|---|
| OpenRouter free-model sync | **Shipped** | `app/services/free_models/sync.rb`, `app/jobs/free_models/sync_job.rb`, GoodJob cron entry `free_models_sync` |
| Deterministic free-model classification | **Shipped** | `app/services/free_models/classify.rb`, `spec/services/free_models/classify_spec.rb` |
| Quality filtering / quality-bar marking | **Shipped** | `app/services/free_models/quality_filter.rb`, `app/services/free_models/sync.rb`, `spec/services/free_models/sync_spec.rb` |
| Default runner selection avoids weak free models | **Shipped** | `app/services/free_models/default_tier_models.rb`, `spec/services/free_models/default_tier_models_spec.rb` |

## What Shipped

### OpenRouter free-model sync

- `app/services/free_models/sync.rb` filters OpenRouter payloads to models whose
  prompt and completion pricing are both `"0"`, upserts `LlmModel` rows with
  `pricing_tier: "free"` and `catalog_source: "openrouter_sync"`, persists
  expiration dates, links `free_variant_of`, and deactivates missing synced
  rows.
- `app/jobs/free_models/sync_job.rb` delegates to the sync service, and
  `config/initializers/good_job.rb` schedules the job daily on the maintenance
  queue with single-flight concurrency.

### Deterministic classification and quality-bar marking

- `app/services/free_models/classify.rb` implements the deterministic scoring
  heuristic from the phase-2 issue: base score, context bonuses, tool support,
  reasoning, output-token bonuses, and multimodal bonus, then maps score to
  `high` / `mid` / `low`.
- `app/services/free_models/quality_filter.rb` applies the minimum criteria of
  `128_000` context tokens plus tool support.
- `app/services/free_models/sync.rb` writes the result into
  `metadata["below_quality_bar"]`.

### Runner defaults and rotation respect the quality bar

- `app/services/free_models/default_tier_models.rb` selects the highest-capability
  active synced free model per tier after rejecting models marked
  `below_quality_bar`.
- `app/services/free_models/rotation.rb` also skips below-bar models by default
  unless explicitly asked to include them.
- `app/models/runner.rb` uses `FreeModels::DefaultTierModels.call` when creating
  or initializing an `openrouter_free` runner without explicit tier mappings.

### Tests covering the previously open gap

- `spec/services/free_models/sync_spec.rb` covers free-model sync, catalog
  attributes, deterministic tiering, quality-bar marking, paid-variant linking,
  deactivation of disappeared models, and idempotency.
- `spec/services/free_models/classify_spec.rb` covers the classification
  heuristic.
- `spec/jobs/free_models/sync_job_spec.rb` covers the scheduled job boundary.
- `spec/services/free_models/default_tier_models_spec.rb` covers the
  above-quality-bar default selection rule.

## Remaining Gaps

No remaining free-model catalog or runner gaps were identified in the scope of
this audit. The implementation matches the work tracked by the closed phase
chain, so no new follow-up issue was filed.

## Conclusion

RDR-038 should now be treated as **Implemented**. The stale note saying OpenRouter
model sync/classification/quality filtering was unimplemented and still tracked
by [#2380](https://github.com/viamin/paid/issues/2380) is no longer correct and
should be removed from the RDR and RDR index.
