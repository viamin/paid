# Plan: Address Unresolved Review Threads on #2617

## Context

PR #2617 (`fix(runners): Opencode MiniMax configured with non-existent model id`) has two unresolved review threads from `paid-code-reviewer`. The task is to address both, scan the rest of the diff for similar issues, then commit.

## Review Threads

### Thread 1 (runner.rb:552) — dead code after the refactor

After the PR refactored `ensure_direct_outbound_llm_model!` to look up the catalog instead of creating rows, two helpers have no remaining callers in `app/`, `lib/`, or `spec/`:

- `Runner::DIRECT_OUTBOUND_MODEL_TIER_HINTS` (lines 107-111) — only referenced by the historical migration `db/migrate/20260504222628_backfill_direct_outbound_provider_tier_models.rb`. Migrations are one-time scripts; this constant is no longer needed in the model.
- `Runner#direct_outbound_display_name` (lines 782-785) — same story; only the migration references it.

**Fix:** delete both. The migration already inlines its own copy of the helpers so removing them from the model is safe.

### Thread 2 (runner.rb:1328) — no operator path to populate catalog for direct-outbound providers

The new validation `direct_outbound_config_models_must_exist_in_catalog` rejects any runner whose configured model id is not already in the `LlmModel` catalog. Before this PR, `ensure_direct_outbound_llm_model!` lazily created the `LlmModel` row on first dispatch via `find_or_create_by!`, so direct-outbound providers (openrouter, minimax, zai, zai_coding, deepseek, inception, xai) never needed to be seeded in advance.

Now they do — but:

- `Models::SeedKnownModels::KNOWN_MODELS` only seeds anthropic, openai, google models.
- There is no Avo resource, controller, or route to create `LlmModel` rows (verified: `app/avo/resources/` has no `llm_model.rb`; no `LlmModelsController` exists).
- The test layer (`KnownDirectOutboundModels::CATALOG`) already models the exact set of `(api_provider, model_id, provider)` tuples that should be in the catalog, but it lives in `spec/support/` and is invisible to production.

**Consequence:** configuring any new, valid direct-outbound model id (e.g. the openrouter/moonshotai/* family) is blocked with no operator-facing remediation path.

**Fix:** extend `Models::SeedKnownModels::KNOWN_MODELS` with the known direct-outbound `(api_provider, model_id, provider)` tuples. The test layer already enumerates them via `KnownDirectOutboundModels::CATALOG`; we should not duplicate that list (test fixtures are not a source of truth for production seeding), so instead seed a small, curated, *conservative* set of well-known direct-outbound model rows. We will:

1. Add a `DIRECT_OUTBOUND_KNOWN_MODELS` constant to `Models::SeedKnownModels` covering the same models that production runners actually use today (those enumerated by the existing migrations, the smoke helpers, and the spec fixtures). This makes the seed list small and reviewable.
2. Wire it into the `call` loop the same way as `KNOWN_MODELS` (use `find_or_initialize_by(model_id:)` so we never overwrite an existing operator-curated row's display name, but still create the row when missing).
3. Keep `KNOWN_MODELS` (the registry-sourced anthropic/openai/google set) untouched — its `find_or_initialize_by` + `assign_attributes(merged_attributes(...))` path is intentionally richer than the direct-outbound seed (no registry row exists for them).

This gives operators the missing path: any runner config using one of the seeded direct-outbound models will pass validation; anything else will continue to surface a clear save-time error so it can be added deliberately via the seed mechanism (PR + migration / spec-driven seeder) rather than silently passing preflight at dispatch.

## Implementation Steps

1. Delete `DIRECT_OUTBOUND_MODEL_TIER_HINTS` constant (runner.rb lines 107-111).
2. Delete `direct_outbound_display_name` method (runner.rb lines 782-785).
3. Add `DIRECT_OUTBOUND_KNOWN_MODELS` to `Models::SeedKnownModels` covering production-validated direct-outbound models: openrouter (moonshotai/kimi-k2 family), anthropic (claude-sonnet-4-5 etc.), openai (gpt-4o), inception (mercury-2), deepseek (deepseek-chat), minimax (MiniMax-M2.7 family), zai_coding (glm-5.1), zai (glm-5.1-zai).
4. Seed them via `find_or_create_by!` in `Models::SeedKnownModels.call`, separate from the registry-snapshot path so existing registry behavior is unchanged.
5. Add a small unit test to `spec/services/models/seed_known_models_spec.rb` that exercises the direct-outbound seeding.
6. Re-run lint and the relevant specs.

## Files to Touch

- `app/models/runner.rb` (delete dead code)
- `app/services/models/seed_known_models.rb` (extend seed list)
- `spec/services/models/seed_known_models_spec.rb` (cover new seed entries)

## Verification

- `bundle exec rubocop`
- `bundle exec rspec spec/models/runner_spec.rb spec/services/models/seed_known_models_spec.rb`

## Risks

- Operators with custom `LlmModel` rows for the seeded ids would not be affected (seed uses `find_or_create_by!` and never overwrites existing rows).
- Adding entries to the seed does not change behavior for any existing valid runner config; it only adds *new* valid model ids to the catalog.
