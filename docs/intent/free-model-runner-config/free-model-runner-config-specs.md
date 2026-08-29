# EARS Specs: Free Model Runner Configuration

> Testable claims for free-policy (`model_policy: "free"`) runner defaults
> and form behavior. Status markers: `[x]` implemented · `[ ]` active gap ·
> `[D]` deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r FREE-MODEL-RUNNER-001`).

## Defaults

- [x] **FREE-MODEL-RUNNER-001** — When the system resolves default tier
  mappings for a free-policy direct-outbound runner, it SHALL select the
  highest capability active synced free model above the quality bar for each
  tier from `LlmModel`.
- [x] **FREE-MODEL-RUNNER-002** — When a new runner is initialized or created
  with `model_policy: "free"` and no explicit values, the system SHALL
  pre-populate `tier_model_ids` from `FreeModels::DefaultTierModels`, set
  `fallback_role: "rate_limit_fallback"`, and default the agent-run, chat, and
  fallback enabled flags to `true`.
- [x] **FREE-MODEL-RUNNER-003** — When the user explicitly supplies
  `fallback_role`, `tier_model_ids`, or enabled flags for a new free-policy
  runner, the system SHALL preserve those submitted values instead of
  overwriting them with suggestions.

## Form Experience

- [x] **FREE-MODEL-RUNNER-004** — When the runner form renders a runner whose
  `model_policy` is `"free"`, it SHALL show a dedicated free-model
  configuration section with tier-model selectors backed only by synced free
  models.
- [x] **FREE-MODEL-RUNNER-005** — The free-model selectors SHALL group models
  by tier and visually distinguish below-quality-bar options in the picker.
- [x] **FREE-MODEL-RUNNER-006** — The free-runner form SHALL explain how
  project data classification maps to OpenRouter routing and SHALL show the
  expected free-model rate limit of about 20 requests per day without
  OpenRouter credits.
