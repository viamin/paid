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

- [x] **SUBSCRIPTION-RUNNER-AUTH-004** — The Connect Codex (`/codex_login_sessions/new`)
  and Claude Browser Login (`/claude_login_sessions/new`) pages SHALL surface
  the account's active managed credential for the matching runner key — name,
  status, and expiry only, never token material — with a link to the credential
  and a note that another login creates a second concurrent credential, and
  SHALL render exactly the fresh login flow when no active credential exists.
  *Tests:* `spec/requests/codex_login_sessions_spec.rb`,
  `spec/requests/claude_login_sessions_spec.rb`,
  `spec/models/runner_credential_spec.rb`.
  *Code:* `ActiveRunnerCredentialStatus`, `CodexLoginSessionsController`,
  `ClaudeLoginSessionsController`, `RunnerCredential#expiry_label`.

- [x] **SUBSCRIPTION-RUNNER-AUTH-005** — Paid SHALL expose a provider-neutral
  runner login-flow registry that renders only registered flows, SHALL allow
  Claude-browser login to target `omp`, SHALL allow OpenAI device-code login to
  target `opencode`, and SHALL materialize the captured managed credentials into
  each runner's native auth state with runner-key-specific telemetry.
  *Tests:* `spec/requests/runner_login_flows_spec.rb`,
  `spec/services/claude_login_sessions/interactive_login_spec.rb`,
  `spec/services/codex_login_sessions/device_flow_spec.rb`,
  `spec/services/containers/provision_runner_login_flows_3463_spec.rb`.
  *Code:* `RunnerLoginFlows::Registry`, `ClaudeLoginSessionsController`,
  `CodexLoginSessionsController`, `Runners::SubscriptionAuthProviders`,
  `Runners::SubscriptionAuthMaterializers`, `Containers::Provision`.
