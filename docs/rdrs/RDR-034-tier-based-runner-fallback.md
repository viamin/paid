# RDR-034: Tier-Based Runner Fallback (Decouple Agent Runs from Concrete Models)

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-05-23
- **Status**: Implemented
- **Type**: Architecture
- **Priority**: P1
- **Related Issues**: #2235, #2236, #2237, #2238, #2239, #2240
- **Related RDRs**: RDR-007 (Agent CLI Abstraction), RDR-008 (Model Selection Strategy), RDR-025a (Runner Quota Tracking)

## Implementation Status

Implemented with minor accepted divergences. Paid filters fallback runners by tier support, resolves concrete models per runner attempt, records resolved attempt metadata, supports runner tier model maps, and fingerprints bundles by tier/selector metadata. The optional `selector_type: tier_only` and `model_pin` escape hatch described here were not implemented; file follow-up work only if those remain desired.

## Problem Statement

Runner fallback is silently disabled whenever the orchestration strategy pins a concrete model that only one runner can execute. In production this manifests as: a preflight timeout (or any other recoverable failure) on the primary runner fails the entire run instead of falling back to a configured alternate runner.

Concrete example (run 19487):

1. Meta-agent selects `claude-sonnet-4-6` (provider `anthropic`, tier `mid`) for the run.
2. Owner has `fallback_enabled = true` and `fallback_runners = [codex, kilocode/glm-5.1, opencode/kimi-k2]`.
3. [`build_runner_order`](../../app/temporal/activities/run_agent_activity.rb#L826-L833) calls `runner_compatible_with_model?` for every candidate against `claude-sonnet-4-6`. Codex fails provider-family (`openai` ≠ `anthropic`). Kilocode/opencode/pi each fail because their `direct_outbound_model_id` is a different concrete id.
4. After filtering, runners collapses to `[claude]` — the primary.
5. Claude's preflight times out at 10s. The `PreflightTimeoutError` rescue records the attempt and increments `index`, but the loop has no further candidates. Run terminates with `All runners exhausted: Claude`. `runner_switches: 0`.

The underlying coupling is broader than the filter: `agent_run.model_selection.llm_model_id` pins a single concrete model id at run-creation time, and ~15 downstream consumers (provider runtime construction, harness validation, bundle fingerprint, quality escalation, surrogate outcomes, cost tracking) read that id as the contract. Any fix that loosens the fallback filter in isolation creates an inconsistency: the run says "I selected claude-sonnet-4-6," but execution actually used `moonshotai/kimi-k2` on the kimi fallback runner, and downstream analytics will mislabel the run.

Requirements:

- Runner fallback must not be disabled by model selection. A user who configures multiple fallback runners should see those runners attempted, regardless of which concrete model the primary runner would have used.
- Tier semantics must be preserved end-to-end. If the meta-agent picks `mid`, every attempted runner (primary and fallbacks) should execute at the `mid` tier.
- Mixed provider topologies are first-class. Some users have one API key per provider family (Anthropic, OpenAI, Google). Others have a single multi-family aggregator (OpenRouter, etc.) and run several model families through one runner.
- Quality escalation, A/B grouping, and cost analytics must remain meaningful when the unit of analysis shifts from "model id" to "tier + resolved model id at exec time."
- No silent behavior change for existing runs. Already-completed runs keep their recorded `llm_model_id`; the change is to how *future* runs resolve a model.

## Context

### Current Behavior

```
                          ┌───────────────────────────────────┐
                          │ CreateAgentRunActivity            │
                          │  - meta-agent picks tier + model  │
                          │  - writes model_selections row    │
                          │    (llm_model_id = claude-…)      │
                          └────────────────┬──────────────────┘
                                           │
                          ┌────────────────▼──────────────────┐
                          │ RunAgentActivity                  │
                          │  - build_runner_order             │
                          │     fallback list ∪ {primary}     │
                          │  - filter by runner_compatible    │
                          │     _with_model?(selected_model)  │
                          │  - loop, attempt each runner with │
                          │    AgentHarness::ProviderRuntime  │
                          │    (model: selected_model_id)     │
                          └───────────────────────────────────┘
```

`model_selections` already carries `tier` (`low | mid | high`) alongside `llm_model_id`. The data model can express "tier first" today; the *flow* is what pins to a concrete id early.

### Configuration Topology Today

- `LlmModel` is the catalog (model_id, provider, tier, capabilities).
- `Provider` (a.k.a. user-attached provider credential) carries the API key for a specific provider family (`anthropic`, `openai`, …) or for a multi-family aggregator.
- `Runner` defines an execution surface (Claude CLI, Codex CLI, Kilocode, Opencode, Pi…). Direct-outbound runners (`kilocode`, `opencode`, `pi`) carry a `direct_outbound_model_id` because the API endpoint they target is hardcoded to one model.
- `UserSetting.fallback_runners` is the user-configured priority list.
- `Runners::DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER` is a static map of single-family runner_key → provider.

Today, tier→model resolution happens in *one* of three places:

1. Meta-agent picks a concrete `LlmModel` (writes both `tier` and `llm_model_id`).
2. Rules-based fallback inside `ModelSelectionService` picks a concrete `LlmModel`.
3. For direct-outbound runners, `Runner#direct_outbound_model_id` is the de-facto resolution — but it's only consulted when *that runner* is selected. There's no mechanism that says "for tier `mid`, runner kilocode should resolve to `glm-5.1`; runner opencode should resolve to `kimi-k2`."

### Why a Localized Fix Is Insufficient

Loosening the model-compatibility filter (the smallest possible change) restores fallback attempts, but every runner attempt that uses its native model still records `agent_run.model_selection.llm_model_id = claude-sonnet-4-6` even when the actual call went to `moonshotai/kimi-k2`. That breaks:

- **Cost attribution** — token-cost rollups look up rates by `llm_model_id`.
- **Quality escalation** — [`ModelEscalation`](../../app/services/quality_recovery/model_escalation.rb) compares historical outcomes by `model_selections.llm_model_id`.
- **Bundle fingerprinting** — [`BundleFingerprinting#model_selection_definition`](../../app/services/configuration_bundles/bundle_fingerprinting.rb#L32) hashes the concrete id into the bundle identity.
- **Surrogate outcome model** — [`SurrogateOutcomeModel`](../../app/services/configuration_bundles/surrogate_outcome_model.rb) uses `model_selection` as a feature.

Either the contract is "agent_run is bound to a concrete model" (today) or "agent_run is bound to a tier and the runner resolves the model" (proposed). Hybrids leak.

## Proposed Solution

### Tier-as-Contract

Agent runs select a **tier**. Each runner (or, for single-family providers, each provider credential) declares which concrete model it uses for each tier. At runner-attempt time, the harness resolves `(runner, tier) → concrete_model_id` and records the resolved id as the runner attempt's `resolved_model_id`, separate from the run-level `tier`.

Fallback becomes "find runners that support this tier" rather than "find runners compatible with this concrete model."

### Data Model Changes

#### `model_selections`

- Keep `tier` as the run-level contract (already exists, NOT NULL going forward).
- Demote `llm_model_id` to "the model the primary runner attempted first" (informational, nullable). New runs may leave it null until the first attempt resolves.
- Add `selector_type` value `tier_only` for runs that skip per-model selection entirely.

#### `runner_attempts` (or `agent_runs.runners_attempted` JSON column)

- Add `resolved_model_id` and `resolved_provider` fields on each attempt. Cost and quality analytics shift from `model_selections.llm_model_id` to the per-attempt resolved id.

#### `Runner.tier_models`

New JSON column on `runners`:

```jsonc
{
  "low":  { "model_id": "kimi-k2-mini", "provider_id": 17 },
  "mid":  { "model_id": "moonshotai/kimi-k2", "provider_id": 17 },
  "high": null
}
```

When `tier_models[tier]` is null for a runner, that runner does not support the requested tier and is skipped during fallback (this is the legitimate case the user named: "some runners may not have a high tier model").

For direct-outbound runners with a single fixed model, the existing `direct_outbound_model_id` migrates into `tier_models` at the tier appropriate for that model (looked up from `LlmModel.tier`).

#### `Provider.tier_models`

Same shape as above, but on the provider credential. Used when the runner does *not* pin a fixed model and instead routes through a single-family provider (e.g. Claude CLI → Anthropic API). The resolution precedence at exec time is:

1. `Runner#tier_models[tier]` if set (direct-outbound or aggregator runner).
2. Else `Provider#tier_models[tier]` for the provider credential bound to this runner.
3. Else fall through to today's `Runners::DefaultTierModelIds` defaults.

This naturally handles the two topologies the user named:

- **Single-family API key (anthropic, openai, …)** — user sets tier→model on the *provider*. All runners that use that provider inherit it.
- **Multi-family aggregator (OpenRouter, …)** — user sets tier→model on the *runner*, because the same provider credential serves multiple families and the choice is runner-scoped.

### Runtime Resolution

```ruby
# app/services/runners/resolve_tier_model.rb (new)
module Runners
  class ResolveTierModel
    include Servo::Service

    input do
      attribute :runner, Dry::Types["any"]
      attribute :tier,   Dry::Types["strict.string"]
      attribute :user,   Dry::Types["any"]
    end

    output do
      attribute :model_id,    Dry::Types["strict.string"]
      attribute :provider_id, Dry::Types["coercible.integer"]
      attribute :source,      Dry::Types["strict.string"] # runner | provider | default
    end

    def call
      runner_entry = runner.tier_models&.dig(tier)
      return success(**runner_entry.merge(source: "runner")) if runner_entry

      provider = user.provider_for(runner)
      provider_entry = provider&.tier_models&.dig(tier)
      return success(**provider_entry.merge(source: "provider")) if provider_entry

      default = DefaultTierModelIds.call(runner_key: runner.runner_key)[tier]
      return failure(error: "no model configured for #{runner.runner_key} at #{tier}") unless default

      success(model_id: default, provider_id: provider&.id, source: "default")
    end
  end
end
```

The runner loop in [`run_agent_activity.rb`](../../app/temporal/activities/run_agent_activity.rb) changes shape:

```ruby
# Today: filter by model, then iterate
runners = compatible_with_model(runners, selected_model)
runners.each do |runner|
  runtime = AgentHarness::ProviderRuntime.new(model: selected_model_id)
  attempt(runner, runtime)
end

# Proposed: filter by tier support, resolve per attempt
runners = supporting_tier(runners, tier)
runners.each do |runner|
  resolved = Runners::ResolveTierModel.call(runner: runner, tier: tier, user: user)
  next if resolved.failure? # runner doesn't support tier — log + skip
  runtime = AgentHarness::ProviderRuntime.new(model: resolved.model_id)
  attempt(runner, runtime, resolved: resolved)
end
```

`runner_compatible_with_model?` becomes `runner_supports_tier?` and inspects `runner.tier_models[tier]` (or, if absent, the bound provider's `tier_models[tier]`).

### Decision Rationale

1. **Fallback is the point.** Fallback exists precisely for the case where the primary fails. Tying fallback eligibility to a concrete model id makes fallback brittle exactly when it's most needed (preflight failure, rate limit, infra failure on the primary).
2. **Tier already exists.** `LlmModel.tier` and `model_selections.tier` are first-class — this RDR makes tier load-bearing rather than vestigial.
3. **The Bitter Lesson, applied consistently.** RDR-008 argued model choice should be data, not code. RDR-034 extends that: the *binding* of tier→model is also data (per-runner, per-provider), not a hardcoded `RUNNER_KEY_TO_MODEL_PROVIDER` map.
4. **Mixed topology is real.** Single-family and multi-family providers are both common. A single source of truth on either runner or provider (with explicit precedence) covers both without conditional logic per provider type.
5. **Per-attempt resolved_model_id keeps analytics honest.** Cost, quality, and outcome analytics already read attempt-level data; promoting `resolved_model_id` to a first-class attempt field lets the rest of the system see what actually ran.

## Alternatives Considered

### Alternative 1: Loosen the Filter Only

**Description**: Drop the `direct_outbound_model_id` mismatch check from `runner_compatible_with_model?`. Let fallback runners use their native models.

**Pros**:

- Single-file change. Ships today.
- Unblocks dev runs immediately.

**Cons**:

- `agent_run.model_selection.llm_model_id` lies about what executed.
- Cost rollups, quality escalation, bundle fingerprinting all become noisy.
- Doesn't address the architectural issue; just hides it behind a working symptom.

**Reason for rejection (as the long-term answer)**: Adopt this as the tactical fix (issue: TBD) with a TODO referencing this RDR. Reject as the strategic answer because the lie compounds with every analytics integration.

### Alternative 2: Require Fallback Runners to Share Model Family

**Description**: Enforce in validation that all configured fallback runners can execute the primary runner's model.

**Pros**:

- Fallback semantics stay simple ("everyone runs the same model").
- No data-model changes.

**Cons**:

- Forecloses on the user's clearly stated need: kilocode/opencode/pi as fallbacks for claude.
- Pushes the multi-runner-multi-model design (which is the whole point of having multiple runners) into a corner case.

**Reason for rejection**: Contradicts the user's intent and the original RDR-007 rationale for unifying disparate CLI agents.

### Alternative 3: Per-Run Model Override on Fallback

**Description**: Keep `agent_run.model_selection.llm_model_id` as primary, but at fallback time mutate it to whatever the fallback runner uses.

**Pros**:

- No new column.

**Cons**:

- The "selected" model becomes a moving target during a single run's lifetime.
- History queries (`Where llm_model_id = X`) silently shift their meaning depending on whether the run completed before or after fallback fired.
- Bundle fingerprint computed at create time no longer matches the model used at exec time.

**Reason for rejection**: Worse than the current state for analytics.

### Alternative 4: Move Tier→Model Mapping to Project Settings

**Description**: Configure tier→model on the project, not on runner or provider.

**Pros**:

- One place to look for "what does mid mean for this project?"

**Cons**:

- Doesn't address multi-family providers (the same project, with one OpenRouter key, would still need per-runner overrides).
- Pushes operational concerns (which API key is in use) into project config.

**Reason for rejection**: Wrong layer. Tier→model is a property of the execution surface (runner) and the credential (provider), not the project's domain logic.

## Trade-offs and Consequences

### Positive

- Fallback works regardless of which model the primary runner uses.
- Tier semantics are honest end-to-end. `agent_run.tier = "mid"` actually means "the run executed at mid tier on whatever runner succeeded."
- New runners onboard by declaring `tier_models` rather than threading through a hardcoded map.
- A/B testing and outcome analytics gain a cleaner unit of analysis (tier) without losing fidelity (resolved model is still recorded per attempt).

### Negative

- Migration cost. ~15 call sites read `selected_model.model_id`; each one needs to choose between "use the attempt-level resolved id" (cost, quality) or "use the tier" (analytics grouping, escalation policy).
- UX surface grows: a new screen (or two) for per-tier model assignment on runners and providers, plus validation ("you have no mid-tier model configured for this provider — runs requesting mid will fall through to defaults").
- Defaults table (`RUNNER_KEY_TO_MODEL_PROVIDER`) becomes a fallback-of-last-resort instead of the primary source of truth — needs careful seeding for new accounts.

### Risks and Mitigations

- **Risk**: Existing runs and bundles compare `llm_model_id` for identity. Demoting that column breaks fingerprint stability.
  **Mitigation**: Version the fingerprint algorithm. Old bundles keep their old fingerprint; new bundles fingerprint on tier + ordered fallback runner set.

- **Risk**: Quality escalation today re-pins a higher-tier model. With tier-as-contract, escalation just changes the tier and lets the runner resolve.
  **Mitigation**: Acceptable change in semantics — but document it, and verify the escalation tests cover the new flow.

- **Risk**: Users with implicit reliance on "this run will use model X" (e.g. for compliance audit) lose that guarantee.
  **Mitigation**: Optional `model_pin` field on the agent run that, when set, disables fallback to runners that can't run that exact model. Defaults off.

## Implementation Plan

### Phase 0 — Tactical (ship before RDR is implemented)

- Loosen `runner_compatible_with_model?` to permit direct-outbound fallbacks even when their model differs. Mark the change `# TODO(RDR-034): replace with tier-based filter`.
- Record the per-attempt actual model in `runners_attempted[].resolved_model_id` so analytics that already read the attempts array stay accurate.
- Raise the dev-environment preflight timeout from 10s to a configurable value (separate concern, but tracked alongside since it surfaced this bug).

### Phase 1 — Data Model

1. Add `tier_models` JSON column to `runners` and `providers`. Default `{}`.
2. Add `resolved_model_id` and `resolved_provider_id` to the `runners_attempted` JSON entries (no migration — JSON-only). Or, if `runner_attempts` becomes a table per RDR-025a work, add columns there.
3. Make `model_selections.llm_model_id` nullable; ensure `tier` is NOT NULL.
4. Backfill `tier_models` from `direct_outbound_model_id` for `kilocode`, `opencode`, `pi`.

### Phase 2 — Resolution Service

1. Implement `Runners::ResolveTierModel` per above.
2. Implement `Runner#supports_tier?(tier)` and `Provider#supports_tier?(tier)`.
3. Switch `build_runner_order` to filter by tier support instead of model compatibility.
4. Switch the per-attempt loop to call `ResolveTierModel` and pass the resolved id into the harness.

### Phase 3 — Consumer Migration

1. `quality_recovery/model_escalation.rb`: escalate by tier; let the runner resolve. Update tests.
2. `configuration_bundles/bundle_fingerprinting.rb`: version the algorithm. New bundles fingerprint on tier + runner set.
3. `configuration_bundles/surrogate_outcome_model.rb`: features keyed on tier; preserve historical `llm_model_id` data for old rows.
4. Cost tracking: read `resolved_model_id` from the attempt rather than `model_selections.llm_model_id`.

### Phase 4 — UX

1. Runner settings: per-tier model picker (visible when the runner is a multi-family aggregator).
2. Provider settings: per-tier model picker (visible when the provider is single-family).
3. Validation: warn when a runner+tier resolves to "default" rather than an explicit setting; block save when no model is resolvable for a tier the user has selected as primary.

### Phase 5 — Deprecation

1. Remove the `runner_compatible_with_model?` filter once the tier-based filter is wired everywhere.
2. Document `RUNNER_KEY_TO_MODEL_PROVIDER` as last-resort defaults; encourage explicit configuration.

## Validation

### Test Scenarios

1. **Primary fails preflight, fallback runs at same tier**: Claude (mid) times out; kilocode (mid) succeeds. `agent_run.tier = "mid"`, attempt 0 resolved_model = `claude-sonnet-4-6`, attempt 1 resolved_model = `glm-5.1`. Run succeeds.
2. **No runner supports requested tier**: User picks `high`; no configured runner has a high-tier model. Run fails fast with `NoTierCapableRunner`, not after exhausting attempts.
3. **Mixed topology**: User has Anthropic provider with `mid → claude-sonnet-4-6`, OpenRouter provider with `mid → kimi-k2` (set on the runner, not the provider). Claude fallback to OpenRouter runner uses the runner-scoped model.
4. **Quality escalation across tiers**: A run at `mid` escalates to `high`. The runner is re-resolved at the new tier; no concrete model is re-pinned at the run level.
5. **Backward compat**: A run created before RDR-034 with `llm_model_id` set still executes against that exact model (model_pin path).

### Performance

- Per-attempt tier resolution is a constant-time lookup (JSON-on-runner + JSON-on-provider). No new DB queries on the hot path.

### Security

- No new credential handling. Existing per-provider RLS and tenant scoping cover the new columns.

## Open Questions

1. **Tier granularity** — Three tiers (low/mid/high) are coarse. Do we need a fourth ("reasoning", "fast")? Probably not for this RDR — handle as future work if A/B data shows the three are insufficient.
2. **Default tier when meta-agent disabled** — Today `ModelSelectionService` picks a concrete model via rules. New default: pick a tier via rules, let runner resolve. Need to confirm the rules-based path still produces predictable cost outcomes.
3. **Model pin escape hatch** — Should `model_pin` be per-run, per-issue label, or per-project? Lean per-run with a default from project settings.
4. **Cost budget interaction** — Budget checks today estimate `cost_per_1k` from `selected_model`. With tier-only selection, the estimate needs to consider all candidate resolved models. Probably take the max across the runner fallback chain to stay safe.

## References

- [RDR-007](RDR-007-agent-cli-abstraction.md) — agent-harness as the LLM interface
- [RDR-008](RDR-008-model-selection.md) — meta-agent + rules selection (extended, not replaced, by this RDR)
- [RDR-025a](RDR-025a-runner-quota-tracking.md) — runner-level state (rate limit, circuit breaker)
- [`run_agent_activity.rb:826-833`](../../app/temporal/activities/run_agent_activity.rb#L826-L833) — current model-compat filter
- [`run_agent_activity.rb:731-749`](../../app/temporal/activities/run_agent_activity.rb#L731-L749) — `runner_compatible_with_model?`
- [`default_tier_model_ids.rb`](../../app/services/runners/default_tier_model_ids.rb) — hardcoded runner→provider map
- [`model_escalation.rb`](../../app/services/quality_recovery/model_escalation.rb) — current quality-tier escalation flow
