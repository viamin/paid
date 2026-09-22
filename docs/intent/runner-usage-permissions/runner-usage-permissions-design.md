---
parent: PAID
prefix: RUNNER-USAGE
---

# Low-Level Design: Runner Usage Permissions

> Companion to [`docs/high-level-design.md`](../../high-level-design.md).
> Establishes independent usage permissions for runner records so that
> `enabled_for_fallback` can never bypass the usage context it modifies.
> Fixes the divergence behind run 7417 (#3974), where a chat-only fallback
> runner (`enabled_for_agent_runs: false`, `enabled_for_chat: true`,
> `enabled_for_fallback: true`) was attempted for an agent run.

## Purpose

A runner carries three independent permission flags:

- `enabled_for_agent_runs` — permits use for agent runs, including both
  initial selection and fallback.
- `enabled_for_chat` — permits use for chat sessions, including both initial
  selection and fallback.
- `enabled_for_fallback` — a shared *modifier*: it additionally permits
  fallback within each usage context that is already enabled. It grants no
  usage permission on its own.

The permissions are necessary conditions, never overrides: global fallback
switches (`UserSetting#fallback_enabled`), saved fallback ordering, tier
support, availability checks, time windows, and rate-limit-only roles
(`fallback_role: "rate_limit_fallback"`) continue to apply on top of them.

| Agent runs | Chat | Fallback | Permitted usage |
| --- | --- | --- | --- |
| Off | On | On | Chat primary and chat fallback only |
| On | Off | On | Agent primary and agent fallback only |
| On | On | On | Primary and fallback in both contexts |
| On | On | Off | Primary in both contexts; no fallback |
| Off | Off | On | Neither context; fallback grants no independent permission |

## Enforcement Points

Agent-run fallback eligibility is resolved from live Runner records at
execution time, so a saved order, a routing identifier saved on a run, or a
settings change after queuing cannot bypass the permission flags:

1. **`UserSetting.fallback_candidate_runners` /
   `UserSetting#allowed_runner_identifiers_for_fallback`** — the standard
   agent fallback candidate set requires `for_agent_runs.for_fallback`.
   Because `#fallback_priority_for` re-derives candidates at execution time
   and drops saved-order tokens that no longer resolve to candidates, a
   runner disabled for agent runs after configuration drops out of the
   fallback chain.
2. **`Activities::RunAgentActivity#load_rate_limit_fallbacks`** — the
   rate-limit fallback map requires `for_agent_runs.for_fallback`, so
   rate-limit-only roles cannot bypass agent usage permission either.
3. **`Activities::RunAgentActivity`** execution loop — routing-key entries
   whose Runner record is no longer enabled for agent runs are skipped and
   recorded as unavailable attempts (mirroring the deleted-entry skip).
4. **`Api::SecretsProxyController`** — agent-run containers may only resolve
   stored keys through runner entries enabled for agent runs. A fallback-only
   entry no longer unlocks key material for an agent run.
5. **`Containers::Provision`** — direct-outbound egress decisions
   (`fallback_runners_require_direct_outbound?`,
   `rate_limit_fallback_runners_require_direct_outbound?`) consult the same
   permission-scoped candidate sets.

Chat fallback eligibility:

6. **`ChatSessions::FallbackRunners`** — both explicitly configured
   (`kb_chat_fallback_runners`) and automatically discovered candidates
   require `enabled_for_chat` **and** `enabled_for_fallback`.

## Stored Flags Are Honored As-Is

No migration or backfill automatically enables agent runs or chat to preserve
the pre-#3974 behavior. Existing "fallback-only" configurations (usage flag
off, fallback flag on) become eligible only for the contexts whose usage flag
is on; to restore agent-run fallback for such a runner the owner re-enables
`enabled_for_agent_runs` explicitly. The shared `enabled_for_fallback` flag is
never silently cleared merely because one context is disabled — the agent
runner settings page only reconciles fallback flags for runners enabled for
agent runs, so a chat-only fallback runner keeps its fallback eligibility for
chat.

## Settings Surfaces

- The runner form labels the flags "Use for agent runs", "Use for chat", and
  "Allow fallback for enabled uses", with help text stating that fallback is
  scoped to the uses selected above and enables nothing on its own.
- The agent runner settings page offers fallback ordering only for runners
  enabled for agent runs; the global "Enable automatic runner fallback"
  switch controls whether fallback happens at all, while per-runner flags
  control eligibility. A runner with only Chat and Fallback enabled is a
  chat-only fallback and does not appear in the agent fallback list.

## References

- `app/models/user_setting.rb`
- `app/models/runner.rb`
- `app/temporal/activities/run_agent_activity.rb`
- `app/services/chat_sessions/fallback_runners.rb`
- `app/services/containers/provision.rb`
- `app/controllers/api/secrets_proxy_controller.rb`
- `app/controllers/runners_controller.rb`
