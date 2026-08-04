# EARS Specs: Subscription Runner Auth

> Testable claims for the implemented managed subscription-runner auth
> lifecycle. Status markers: `[x]` implemented · `[ ]` active gap · `[D]`
> deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r SUBSCRIPTION-RUNNER-AUTH-001`).

- [x] **SUBSCRIPTION-RUNNER-AUTH-001** — The managed subscription-auth
  registry SHALL expose canonical provider facts for materialization mode,
  rotation risk, and remote-safety, including the shipped exception that Codex
  remains not remote-safe while Gemini and Copilot are remote-safe.
  *Tests:* `spec/services/runners/subscription_auth_providers_spec.rb`,
  `spec/services/runners/subscription_auth_materializers_spec.rb`.
  *Code:* `Runners::SubscriptionAuthProviders`,
  `Runners::SubscriptionAuthMaterializers`.

- [x] **SUBSCRIPTION-RUNNER-AUTH-002** — When Paid provisions Codex with a
  managed credential, the system SHALL materialize native `auth.json`, SHALL
  keep the canonical credential state in Paid through harvest/writeback, and
  SHALL emit managed auth telemetry for materialization, harvest, and lease
  stages.
  *Tests:* `spec/services/containers/provision_codex_managed_auth_2962_spec.rb`.
  *Code:* `Runners::SubscriptionAuthProviders`, `Containers::Provision`.

- [x] **SUBSCRIPTION-RUNNER-AUTH-003** — When Gemini or Copilot managed
  subscription auth is enabled, the system SHALL materialize the minimal native
  config from the managed credential and record managed telemetry, while
  preserving the legacy host-forwarded path when rollout is disabled or no
  managed credential exists.
  *Tests:* `spec/services/containers/provision_managed_subscription_auth_2964_spec.rb`.
  *Code:* `Runners::SubscriptionAuthProviders`, `Containers::Provision`.
