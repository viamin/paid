# EARS Specs: Runner Usage Permissions

> Testable claims for independent agent-run/chat usage permissions with
> fallback as a shared modifier. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r RUNNER-USAGE-001`).

## Agent-run fallback permissions

- [x] **RUNNER-USAGE-001** — The system SHALL include a runner in the
  agent-run fallback candidate set only when the runner has both
  `enabled_for_agent_runs` and `enabled_for_fallback` set.
  *Tests:* `spec/models/user_setting_spec.rb` ("#provider_priority",
  "#fallback_priority_for", ".fallback_candidate_runners").
  *Code:* `UserSetting.fallback_candidate_runners`,
  `UserSetting#allowed_runner_identifiers_for_fallback`.

- [x] **RUNNER-USAGE-002** — The system SHALL include a runner in the
  agent-run runtime fallback chain only when the runner has both
  `enabled_for_agent_runs` and `enabled_for_fallback` set, regardless of
  saved fallback order or automatic candidate appending.
  *Tests:* `spec/temporal/activities/run_agent_activity_spec.rb`
  ("does not attempt runners disabled for agent runs as fallback").
  *Code:* `Activities::RunAgentActivity#build_runner_order`.

- [x] **RUNNER-USAGE-003** — The system SHALL insert a rate-limit fallback
  entry into the agent-run attempt chain only when the entry has both
  `enabled_for_agent_runs` and `enabled_for_fallback` set.
  *Tests:* `spec/temporal/activities/run_agent_activity_spec.rb`
  ("does not insert rate-limit fallbacks disabled for agent runs").
  *Code:* `Activities::RunAgentActivity#load_rate_limit_fallbacks`,
  `UserSetting.rate_limit_fallback_runners`.

- [x] **RUNNER-USAGE-004** — When a runner's usage permission is disabled
  after a run is configured or queued, the system SHALL NOT attempt that
  runner at execution time; the attempt SHALL be skipped and recorded as
  unavailable.
  *Tests:* `spec/temporal/activities/run_agent_activity_spec.rb`
  ("skips runners disabled for agent runs after queuing").
  *Code:* `Activities::RunAgentActivity` execution loop.

- [x] **RUNNER-USAGE-005** — An agent-run container SHALL resolve stored API
  keys only through runner entries with `enabled_for_agent_runs` set; the
  fallback flag SHALL NOT unlock key material for agent runs on its own.
  *Tests:* `spec/requests/api/secrets_proxy_spec.rb`
  ("rejects runner ids that are disabled for agent runs even when fallback
  is enabled").
  *Code:* `Api::SecretsProxyController#available_runner_entries`.

## Chat fallback permissions

- [x] **RUNNER-USAGE-006** — The system SHALL offer a runner as an explicitly
  configured chat fallback only when the runner has both `enabled_for_chat`
  and `enabled_for_fallback` set.
  *Tests:* `spec/services/chat_sessions/fallback_runners_spec.rb`
  ("does not use configured chat fallback runners disabled for chat").
  *Code:* `ChatSessions::FallbackRunners.runner_for_identifier`.

- [x] **RUNNER-USAGE-007** — The system SHALL offer a runner as an
  automatically discovered chat fallback only when the runner has both
  `enabled_for_chat` and `enabled_for_fallback` set.
  *Tests:* `spec/services/chat_sessions/fallback_runners_spec.rb`
  ("does not automatically use chat fallback runners disabled for chat").
  *Code:* `ChatSessions::FallbackRunners.for`.

## Preservation semantics

- [x] **RUNNER-USAGE-008** — When `enabled_for_fallback` is false, the
  system SHALL still allow the runner as a primary selection in each usage
  context whose usage flag is enabled.
  *Tests:* `spec/models/user_setting_spec.rb` ("#provider_priority").
  *Code:* `UserSetting#runner_priority`.

- [x] **RUNNER-USAGE-009** — A runner disabled for agent runs but enabled
  for chat and fallback SHALL remain eligible as a chat fallback (and
  vice versa); disabling one usage context SHALL NOT clear the shared
  fallback flag or the other context's eligibility.
  *Tests:* `spec/services/chat_sessions/fallback_runners_spec.rb`
  ("keeps chat fallback eligibility when agent runs are disabled"),
  `spec/models/runner_spec.rb` (`.update_fallback_flags`).
  *Code:* `ChatSessions::FallbackRunners.for`,
  `Runner.update_fallback_flags`.

- [x] **RUNNER-USAGE-010** — The system SHALL honor stored usage flags
  as-is: no code path SHALL automatically enable agent runs or chat to
  preserve legacy fallback-only behavior.
  *Code:* no migration or callback mutates `enabled_for_agent_runs` /
  `enabled_for_chat`; `Runner.update_fallback_flags` only reconciles
  `enabled_for_fallback` for runners enabled for agent runs.

## Settings surfaces

- [x] **RUNNER-USAGE-011** — The agent runner settings page SHALL offer
  fallback ordering only for runners enabled for agent runs, and saving
  those settings SHALL NOT clear `enabled_for_fallback` on runners disabled
  for agent runs.
  *Tests:* `spec/requests/runners_spec.rb` ("PATCH /runners/settings").
  *Code:* `RunnersController#load_index_context`,
  `RunnersController#fallback_candidate_runner_identifiers`,
  `Runner.update_fallback_flags`.

- [x] **RUNNER-USAGE-012** — The runner form and runner overview SHALL
  present usage permissions as "Use for agent runs", "Use for chat", and
  "Allow fallback for enabled uses", making explicit that fallback applies
  only to the uses enabled above and enables no usage on its own.
  *Tests:* `spec/requests/runners_spec.rb` (runner form rendering).
  *Code:* `app/views/runners/_form.html.erb`,
  `app/views/runners/_settings.html.erb`,
  `app/views/runners/index.html.erb`.
