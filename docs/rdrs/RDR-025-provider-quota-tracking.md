# RDR-025: Provider Quota Tracking and Quota-Aware Routing

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-04-19
- **Status**: Superseded
- **Type**: Architecture
- **Priority**: Medium
- **Related Issues**: TBD
- **Related RDRs**: [RDR-007](RDR-007-agent-cli-abstraction.md) (agent-harness), [RDR-008](RDR-008-model-selection.md) (model selection), [RDR-006](RDR-006-secrets-proxy.md) (secrets proxy)

## Implementation Status

Superseded by [RDR-025: Runner Quota Tracking and Quota-Aware Routing](RDR-025-runner-quota-tracking.md), which uses the current runner terminology. The active runner quota RDR is partially implemented: Paid has internal usage and reactive rate-limit state, but not proactive upstream quota polling, snapshots, refresh, display, or quota-aware routing.

## Problem Statement

Paid orchestrates AI coding agents across multiple subscription providers (Claude Code, Codex, GitHub Copilot, Z.ai, Cursor), but has no visibility into how much of each provider's upstream quota remains. Users with active subscriptions (e.g., Claude Pro 5x, Codex Pro, Copilot Business, Z.ai Coding Max) cannot see how close they are to hitting session, weekly, or monthly limits — and Paid cannot make informed routing decisions to avoid providers nearing exhaustion.

Today Paid discovers rate limits only *reactively* when a run fails with a 429 error, triggering circuit-breaker fallback. There is no *proactive* awareness of upstream quota state.

### User Impact

The `test@example.com` user has subscription accounts for Claude Code, Codex, Z.ai, and GitHub Copilot. They need to know:

1. How much of each provider's quota has been consumed (session, weekly, credits)
2. When quotas reset
3. Which provider Paid should prefer based on remaining headroom

### Requirements

- Display per-provider quota status on the `/providers` page
- Poll upstream provider APIs for current quota usage on a schedule
- Use quota data to inform provider selection during agent runs
- Respect the AGENTS.md boundary: provider-specific API knowledge lives in agent-harness, not Paid

## Context

### What Paid Already Tracks

| Data | Source | Location |
|------|--------|----------|
| Per-request tokens + cost per provider | Secrets proxy | `TokenUsage` model |
| Provider health (circuit breaker, rate limits) | RunAgentActivity | `ProviderState` model |
| Provider fallback history | RunAgentActivity | `AgentRun.providers_attempted` |
| Per-project cost budgets | CostBudgets::Check | `CostBudget` model |
| Provider configuration (subscription vs API key) | Provider model | `Provider`, `ProviderApiKey` |
| Dashboard stats by provider | Dashboard::Stats | Aggregation queries |

This data answers "how much has Paid consumed from each provider" but not "how much upstream quota remains."

### What Upstream Provider APIs Expose

Research from viamin/openusage (a macOS menu-bar app that polls these same APIs) reveals:

| Provider | Quota API | Credentials Needed | Quota Types |
|----------|-----------|-------------------|-------------|
| **Claude Code** | `GET api.anthropic.com/api/oauth/usage` | OAuth access_token + refresh_token from `~/.claude/.credentials.json` | Session % (5h rolling), Weekly % (7d rolling), Extra usage $, plan tier |
| **Codex** | `GET chatgpt.com/backend-api/wham/usage` + `x-codex-*` response headers | OAuth access_token from `~/.config/codex/auth.json` | Session % (5h), Weekly % (7d), Reviews limit, Credits balance |
| **GitHub Copilot** | `GET api.github.com/copilot_internal/user` | GitHub token with copilot scope | Premium interactions %, Chat %, Completions count, reset date |
| **Z.ai** | `GET api.z.ai/api/monitor/usage/quota/limit` + `/api/biz/subscription/list` | API key (`ZAI_API_KEY`) | Session % (5h), Weekly % (7d), Web searches count (monthly) |
| **Cursor** | `POST api2.cursor.sh/.../GetCurrentPeriodUsage` (Connect RPC) | OAuth tokens from SQLite state.vscdb | Credits $, Total %, Auto %, API %, On-demand $ |

### Existing Code That Should Be Upstreamed

Before adding quota features, significant provider-specific logic currently in Paid should move to agent-harness per AGENTS.md:

| What | Currently in Paid | Why it belongs in agent-harness |
|------|-------------------|-------------------------------|
| Codex `AUTH_EXPIRED_PATTERNS` | `run_agent_activity.rb:66-74` | Provider-specific auth error phrasing |
| `PROVIDER_ABORT_PATTERNS` | `run_agent_activity.rb:95-103` | Provider-specific hang-on-error knowledge |
| `parse_rate_limit_reset` (duplicated) | `run_agent_activity.rb:830-872`, `test_agent.rb:311-353` | Provider-specific rate limit time formats |
| Provider env var names (`api_key_env_var_names_for`, `SUBSCRIPTION_AUTH_UNSET_VARS`) | `run_agent_activity.rb:1271-1299`, `provider_support.rb:219-238` | Which env vars each CLI reads |
| Codex config TOML format | `provision.rb:722-740` | Provider-specific CLI config format |
| Gemini env vars (`GEMINI_SANDBOX`, etc.) | `provision.rb:1328-1338` | Provider-specific CLI flags |
| Codex OAuth lockfile | `provision.rb:789-802` | Provider-specific OAuth race condition |
| Provider test commands | `test_agent.rb:482-559` | Provider-specific CLI flags |
| Secrets proxy token extraction | `secrets_proxy_controller.rb:138-156` | Provider-specific API response formats |
| TestAgent error patterns | `test_agent.rb:21-105` | Provider-specific error classification |

## Proposed Solution

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      PROVIDER QUOTA TRACKING ARCHITECTURE                    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                  AGENT-HARNESS (upstream gem)                           ││
│  │                                                                          ││
│  │  Per-provider quota method:                                             ││
│  │    AgentHarness.provider_quota(:claude, credentials: {...})             ││
│  │    => QuotaSnapshot(provider, plan, metrics[], fetched_at)              ││
│  │                                                                          ││
│  │  Also upstreams existing:                                               ││
│  │    • Error classification patterns                                      ││
│  │    • Rate limit reset time parsing                                      ││
│  │    • Provider env var names                                             ││
│  │    • Config file formats (Codex TOML, Kilocode JSON)                    ││
│  │    • API response token extraction                                      ││
│  │                                                                          ││
│  └────────────────────────────────┬────────────────────────────────────────┘│
│                                   │                                          │
│                                   ▼                                          │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         PAID (Rails app)                                 ││
│  │                                                                          ││
│  │  New models:                                                            ││
│  │    • ProviderQuotaCredential (encrypted OAuth tokens/API keys)          ││
│  │    • ProviderQuotaSnapshot (cached quota metrics)                       ││
│  │                                                                          ││
│  │  New services:                                                          ││
│  │    • Providers::RefreshQuotas (scheduled job, calls agent-harness)      ││
│  │    • Providers::QuotaScore (scores providers for routing)               ││
│  │                                                                          ││
│  │  Enhanced:                                                              ││
│  │    • /providers UI (quota bars, plan info, reset timers)                ││
│  │    • RunAgentActivity#build_provider_order (quota-aware scoring)        ││
│  │                                                                          ││
│  │  Quick win (existing data, no new credentials):                         ││
│  │    • Per-provider token spend from TokenUsage                           ││
│  │    • Per-provider fallback frequency from providers_attempted            ││
│  │    • Per-provider rate limit event count                                ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Phase 0: Upstream Existing Provider-Specific Code to agent-harness

Before adding quota features, move the provider-specific logic listed above to where it belongs. This creates the right foundation and proves the provider-class extension pattern that quota polling will use.

**In agent-harness**, add to each provider class:

- `env_var_names` → returns env var names this CLI reads for API keys
- `subscription_unset_vars` → returns env vars to strip for subscription auth
- `config_file_format` → returns config file content structure
- `test_command_overrides` → returns additional flags for health-check invocations
- `error_classification_patterns` → returns structured pattern sets for auth_expired, abort, rate_limit
- `parse_rate_limit_reset(text)` → class method to parse provider-specific reset time formats
- `token_usage_from_api_response(body)` → extracts tokens from provider API response shapes

**In Paid**, replace all hard-coded arrays/methods with calls into agent-harness.

### Phase 1: Add Quota Polling to agent-harness

Each provider in agent-harness gets a `quota` interface:

```ruby
AgentHarness.provider_quota(:claude, credentials: {
  access_token: "...",
  refresh_token: "..."
})
# => AgentHarness::QuotaSnapshot(
#   provider: :claude,
#   plan: "Pro 5x",
#   fetched_at: Time.current,
#   metrics: [
#     QuotaMetric::Progress(label: "Session", used: 78.5, limit: 100,
#                           format: :percent, resets_at: 30.minutes.from_now),
#     QuotaMetric::Progress(label: "Weekly", used: 45.2, limit: 100,
#                           format: :percent, resets_at: 5.days.from_now),
#     QuotaMetric::Badge(label: "Peak Hours", text: "Off-Peak"),
#   ],
#   raw_response: { ... }
# )
```

Each provider class gets:

- `supports_quota_polling?` → boolean
- `quota(credentials:)` → calls provider usage API, returns `QuotaSnapshot`
- `quota_credentials_type` → what credentials are needed (`oauth_tokens`, `api_key`, `env_var`)
- `refresh_quota_credentials(credentials:)` → handles token refresh

**Provider-specific implementations:**

| Provider | API Endpoint | Auth | Metrics |
|----------|-------------|------|---------|
| Claude | `api.anthropic.com/api/oauth/usage` | OAuth bearer | Session %, Weekly %, Extra $ |
| Codex | `chatgpt.com/backend-api/wham/usage` | OAuth bearer | Session %, Weekly %, Credits |
| Copilot | `api.github.com/copilot_internal/user` | GitHub token | Premium %, Chat %, Completions |
| Z.ai | `api.z.ai/api/monitor/usage/quota/limit` | API key | Session %, Weekly %, Searches |
| Cursor | `api2.cursor.sh/.../GetCurrentPeriodUsage` | OAuth bearer | Credits $, Total %, API % |

### Phase 2: Display Internal Usage Data in Paid (Quick Win)

On the `/providers` page, add per-provider aggregations from existing data — no new credentials or APIs needed:

- **7-day token spend per provider** — `TokenUsage` joined to `AgentRun.effective_provider`
- **Fallback frequency** — from `providers_attempted` JSON
- **Rate limit event count** — `AgentRun` statuses grouped by provider
- **Circuit breaker state** — already shown, add richer history

### Phase 3: Connect agent-harness Quota Polling to Paid

**New database tables:**

```ruby
create_table :provider_quota_credentials do |t|
  t.references :provider, null: false, foreign_key: true
  t.string :credential_type, null: false  # "oauth", "api_key"
  t.text :access_token                    # encrypted
  t.text :refresh_token                   # encrypted
  t.datetime :expires_at
  t.string :scopes
  t.jsonb :metadata
  t.timestamps
end

create_table :provider_quota_snapshots do |t|
  t.references :provider, null: false, foreign_key: true
  t.string :quota_type, null: false      # "session", "weekly", "monthly", "credits"
  t.string :label
  t.decimal :used, precision: 12, scale: 2
  t.decimal :limit, precision: 12, scale: 2
  t.string :format                       # "percent", "count", "dollars"
  t.string :unit_suffix
  t.datetime :resets_at
  t.integer :period_duration_seconds
  t.string :plan_name
  t.jsonb :raw_response
  t.datetime :fetched_at
  t.timestamps
end
```

**New Paid service:**

```ruby
module Providers
  class RefreshQuotas
    # Scheduled via GoodJob cron (every 15 min)
    # For each user's subscription providers:
    #   1. Load credentials from provider_quota_credentials
    #   2. Call AgentHarness.provider_quota(:claude, credentials: ...)
    #   3. Upsert provider_quota_snapshots
    #   4. Handle token refresh if needed
  end
end
```

**Credential collection:**

| Provider | Approach | Effort |
|----------|----------|--------|
| Z.ai | API key input (reuses `ProviderApiKey` flow) | Low |
| Copilot | GitHub App OAuth scope or PAT | Medium |
| Claude | Opportunistic capture from container after successful auth | High |
| Codex | Opportunistic capture from container after successful auth | High |

For Claude and Codex, the most practical approach is to capture OAuth tokens from the container filesystem after a provider authenticates successfully during an agent run. Paid already seeds credentials into containers; it can read back the refreshed tokens after the run completes.

### Phase 4: Quota-Aware Provider Routing

Enhance provider selection in `RunAgentActivity#build_provider_order`:

```ruby
# After building the ordered list, score each candidate:
#   1. Load latest ProviderQuotaSnapshot for each provider
#   2. Score: session_pct (lower better), weekly_pct (lower better)
#   3. Combine with existing factors: circuit_state, rate_limited_until, weight
#   4. If primary provider session > 80% and fallback has < 50%, prefer fallback
#   5. Log quota-informed routing decision
```

This scoring logic stays in **Paid** (orchestration policy, not provider-specific behavior). Raw quota data comes from **agent-harness**.

### Phase 5: Predictive Analytics

- Use historical `TokenUsage` + `ProviderQuotaSnapshot` data to predict quota exhaustion
- Dashboard cards: "Claude session will likely exhaust in ~2 hours at current pace"
- Auto-suggest: "Copilot premium interactions at 92%. Consider adding Codex API key as fallback."
- Entirely in Paid — analytics and UX, not provider-specific behavior.

## Scope and Boundaries

### agent-harness responsibilities

- Quota API endpoint knowledge and response parsing per provider
- OAuth token refresh flows per provider
- `QuotaSnapshot` / `QuotaMetric` data structures
- Upstreamed provider-specific patterns (error classification, env vars, config formats)

### Paid responsibilities

- Encrypted credential storage for quota polling
- Quota snapshot persistence and scheduled refresh
- Quota display UI on `/providers` page
- Quota-aware routing decisions (scoring policy)
- Internal usage aggregation from existing `TokenUsage` data
- Predictive analytics and user suggestions

### Out of scope

- Billing/invoicing against provider quotas (tracked separately in billing schema)
- Provider account management (sign-up, plan changes)
- Real-time quota webhooks (providers don't offer these)

## Alternatives Considered

### Alternative 1: Build quota polling entirely in Paid

**Description**: Call provider APIs directly from Paid services without going through agent-harness.

**Pros**: Simpler initially, no cross-repo coordination.

**Cons**: Violates AGENTS.md ("All LLM calls must go through agent_harness"). Duplicates provider-specific API knowledge. Harder to maintain when providers change APIs.

**Reason for rejection**: Provider-specific API knowledge belongs in agent-harness per the established architectural boundary (RDR-007).

### Alternative 2: Use OpenUsage's local HTTP API

**Description**: Require users to run OpenUsage alongside Paid, read quota data from `127.0.0.1:6736`.

**Pros**: No credential management needed in Paid. OpenUsage already works.

**Cons**: Requires users to install and run a separate macOS app. Not available on Linux. Single-point-of-failure. No integration with Paid's routing logic.

**Reason for rejection**: Operational complexity for users. Doesn't enable quota-aware routing in Paid.

### Alternative 3: Reactive-only (no proactive polling)

**Description**: Continue relying on circuit breakers and rate limit errors. Don't poll upstream quotas.

**Pros**: Zero implementation effort. Already works today.

**Cons**: No visibility into quota state. Can't proactively avoid nearly-exhausted providers. Users can't see quota status. Preventable failures occur.

**Reason for rejection**: The whole point is proactive awareness. Reactive-only is the status quo we're improving.

## Trade-offs and Consequences

### Positive Consequences

- Users can see all provider quotas in one place
- Paid can avoid routing to nearly-exhausted providers
- Provider-specific knowledge centralized in agent-harness (current violation fixed)
- Foundation for predictive analytics and cost optimization

### Negative Consequences

- New credential storage surface (encrypted OAuth tokens) — security responsibility
- Scheduled polling adds API calls to providers (every 15 min per user per provider)
- Cross-repo coordination between Paid and agent-harness for releases
- Claude/Codex OAuth capture from containers is inherently fragile

### Risks and Mitigations

- **Risk**: Provider APIs change without notice
  **Mitigation**: Fail gracefully — quota snapshots become stale, not broken. Fall back to reactive rate-limit detection.

- **Risk**: OAuth token capture from containers is unreliable
  **Mitigation**: Start with Z.ai (API key) and Copilot (GitHub token). Claude/Codex can remain reactive until a better credential exchange flow is built.

- **Risk**: Polling creates API rate-limit issues
  **Mitigation**: 15-minute interval is conservative. OpenUsage uses similar intervals. Cache aggressively.

- **Risk**: Cross-repo release coordination
  **Mitigation**: agent-harness changes are additive (new methods). Paid can pin to minimum gem version. No breaking changes.

## Implementation Plan

### Effort Estimates

| Phase | Scope | Est. | Notes |
|-------|-------|------|-------|
| Phase 0: Upstream existing code | agent-harness + Paid | 2-3 weeks | Mechanical — move patterns/config into gem provider classes |
| Phase 1: Quota interface in agent-harness | agent-harness only | 3-4 weeks | New types + `provider_quota()` for 4-5 providers |
| Phase 2: Internal usage display | Paid only | 1 week | Query existing data, add to providers page |
| Phase 3: Connect quota polling | Paid (DB + UI + jobs) | 2-3 weeks | New tables, credential storage, scheduled job, UI |
| Phase 4: Quota-aware routing | Paid only | 1-2 weeks | Scoring in `build_provider_order` |
| Phase 5: Predictive analytics | Paid only | 1-2 weeks | Dashboard cards, suggestions |

**Recommended starting point** (4-5 weeks to first useful milestone):

1. Phase 2 first (1 week) — immediate value with existing data
2. Phase 0 next (2-3 weeks) — tech debt payoff that enables everything after
3. Phase 1 for Z.ai only (1 week) — prove the interface with simplest provider

### Prerequisites

- [ ] agent-harness gem repo access for upstream changes
- [ ] Agreement on `QuotaSnapshot` / `QuotaMetric` interface design
- [ ] Security review of OAuth token storage approach

### Files to Create/Modify

**agent-harness (Phase 0):**

- Each provider class: add `env_var_names`, `subscription_unset_vars`, `config_file_format`, `error_classification_patterns`, `parse_rate_limit_reset`, `token_usage_from_api_response`
- New: `lib/agent_harness/quota_snapshot.rb`, `lib/agent_harness/quota_metric.rb`

**agent-harness (Phase 1):**

- Each provider class: add `supports_quota_polling?`, `quota(credentials:)`, `quota_credentials_type`
- Per-provider quota implementations (HTTP calls, response parsing)

**Paid (Phase 2):**

- `app/services/providers/usage_stats.rb` — aggregate TokenUsage by provider
- `app/views/providers/index.html.erb` — add usage column
- `app/views/providers/_quota_display.html.erb` — partial for quota bars

**Paid (Phase 3):**

- `db/migrate/*_create_provider_quota_credentials.rb`
- `db/migrate/*_create_provider_quota_snapshots.rb`
- `app/models/provider_quota_credential.rb`
- `app/models/provider_quota_snapshot.rb`
- `app/services/providers/refresh_quotas.rb`
- `app/jobs/providers/refresh_quotas_job.rb` (GoodJob cron)
- `app/views/providers/index.html.erb` — add quota column
- `config/initializers/agent_harness.rb` — wire quota methods

**Paid (Phase 4):**

- `app/services/providers/quota_score.rb`
- `app/temporal/activities/run_agent_activity.rb` — enhance `build_provider_order`

## Validation

### Testing Approach

1. Unit tests for agent-harness `provider_quota()` per provider (mocked HTTP)
2. Unit tests for `Providers::RefreshQuotas` with mock agent-harness responses
3. Integration test: quota snapshots appear on `/providers` page
4. Integration test: quota-aware routing prefers provider with more headroom
5. Security test: encrypted credential storage and access

### Test Scenarios

1. **Provider at 90% session**: routing should prefer fallback provider
2. **Provider at 100% weekly**: routing should treat as rate-limited
3. **All providers near limit**: routing should spread load proportionally
4. **Quota API returns error**: stale snapshot used, no crash
5. **OAuth token expired**: refresh flow triggered, new token persisted

### Performance Validation

- Quota refresh job completes in < 30s per user (4 providers)
- `/providers` page load adds < 100ms with quota data
- Quota-aware routing adds < 10ms to provider selection

## References

- [RDR-007](RDR-007-agent-cli-abstraction.md) — agent-harness adoption
- [RDR-008](RDR-008-model-selection.md) — model selection strategy
- [RDR-006](RDR-006-secrets-proxy.md) — secrets proxy architecture
- [viamin/openusage](https://github.com/viamin/openusage) — reference implementation for quota polling
- `docs/ROADMAP.md` — Phase 3.5.6 entry
- `AGENTS.md` — provider-specific behavior boundary rule
