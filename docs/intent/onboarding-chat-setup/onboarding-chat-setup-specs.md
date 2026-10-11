# EARS Specs: Onboarding Chat-Led Setup

Status: `[ ]` planned; no implementation is claimed by these specs. Tracked by
umbrella issue #4280; phase issues #4281 (chat bootstrap) and #4282
(onboarding chat tools) implement the claims below and flip their markers to
`[x]` as each ships, with tests and code references added at that point.

- [ ] **ONBOARD-CHAT-001** — When a new account reaches the chat-capable-key
  onboarding step, Paid SHALL present the provider options enumerated from
  `RunnerSupport::API_SERVICE_TYPES` (including OpenRouter's free-model
  option) rather than a separately maintained, divergent list, with one-line
  guidance per option so the user can choose without asking.
- [ ] **ONBOARD-CHAT-002** — When a user submits a provider API key during
  onboarding, Paid SHALL create a `ProviderApiKey`, a chat-enabled API-key
  `Runner` matching the chosen service type (including the OpenRouter
  direct-outbound free-model policy), and a `ChatSession` bound to that
  runner in one transactional step, and SHALL redirect the user into that
  chat session rather than back to a form.
- [ ] **ONBOARD-CHAT-003** — When key creation fails validation (e.g. a
  401/403 from the provider), Paid SHALL surface a friendly retry without
  losing the user's place in the onboarding step.
- [ ] **ONBOARD-CHAT-004** — When an onboarding chat session is active and
  setup is incomplete, `ChatSessions::BuildSystemPrompt` SHALL inject a
  setup-interview persona that asks what tools the user uses (agent-run
  runners, Linear), never re-asks a step `OnboardingStep` already recorded as
  complete, and offers to explain any setting via the product-docs tool.
- [ ] **ONBOARD-CHAT-005** — When the onboarding assistant needs to reason
  about what remains to configure, it SHALL call `get_onboarding_status`,
  `list_runners`, and `get_account_capabilities` to read current state rather
  than inferring or guessing it from conversation history alone.
- [ ] **ONBOARD-CHAT-006** — When the onboarding assistant creates a runner,
  tracker configuration, or project on the user's behalf, it SHALL do so only
  through the confirmed write tools `create_runner`,
  `create_tracker_configuration`, and `create_project`, each requiring
  explicit human confirmation before the write executes; the model SHALL NOT
  be able to set the `confirmed` field itself.
- [ ] **ONBOARD-CHAT-007** — When a tracker configuration requires an OAuth
  handshake, the corresponding write tool SHALL return a connect URL for the
  user to follow rather than attempting the handshake inside the chat.
- [ ] **ONBOARD-CHAT-008** — When a chat-guided onboarding step is completed,
  the assistant SHALL record it through `complete_onboarding_step`
  (delegating to `Onboarding::CompleteStep`); no tool SHALL exist that skips
  or fast-forwards a step without it being actually configured.
- [ ] **ONBOARD-CHAT-009** — When a user asks what a setting or Paid feature
  is for, the assistant SHALL answer using `get_product_docs` against a
  curated, version-controlled docs corpus, and SHALL NOT answer from model
  memory alone.
- [ ] **ONBOARD-CHAT-010** — When onboarding completes, Paid SHALL consider
  the account minimally set up only once it has a chat-capable runner, at
  least one project, a GitHub credential, an agent-run runner, and a chosen
  operating profile recorded in `OnboardingStep` state, with Linear optional.
- [ ] **ONBOARD-CHAT-011** — While the chat-led flow is available, the
  existing form-based onboarding steps SHALL remain independently usable
  end-to-end, and progress made through either path SHALL be reflected in the
  same shared `OnboardingStep` records.
- [ ] **ONBOARD-CHAT-012** — When a tool result would otherwise include a
  provider secret, every onboarding tool response SHALL mask it (e.g.
  `masked_api_key`) and SHALL NOT include the raw secret value.
- [ ] **ONBOARD-CHAT-013** — When `create_runner` receives a
  `provider_api_key_id`, it SHALL reject any key that does not belong to the
  current user/account rather than attaching another tenant's credential.
