---
parent: PAID
prefix: LLM-ROUTING
---

# Application LLM routing

Application text operations route through `Llm::Request` and `agent_harness`.
A run's effective runner and tier take precedence. Other operations use the
project owner's configured chat runner, then their default runner if enabled
for chat, then an enabled chat runner in saved priority order. Account work
uses the account's fallback owner; interactive global work uses the current
actor. Missing ownership or eligible configuration is an explicit error.

Existing user chat-runner and runner settings select the provider. Project
model and provider policy remains authoritative. No new vendor selector is
needed for each helper. Fallback follows user permission flags and configured
order within one shared timeout budget. Requests use the harness's explicit
execution boundary, bypassing its process-wide provider substitution. A default stored in settings is not proof the owner
has configured that vendor: routing must resolve a live, permitted Runner.

Text operations accept subscription and API-key runners. The existing chat-runner setting accepts owned runner identifiers, allowing
multiple configurations behind the same CLI to remain distinguishable. API credentials
come from the selected runner; unrelated host environment keys cannot change
billing mode. Managed subscription credentials need an isolated environment.
Standalone API-key requests use the harness API transport directly, avoiding
CLI startup and host repository instructions. Native host subscriptions unset
conflicting API authentication variables. A
host CLI must advertise reliable tool control; other drivers require API text
transport with explicit runner credentials or an isolated environment. A
`tools: none` option alone is not evidence that a driver disables its tools.
When a standalone caller widens from saved preferences, it filters owned runner
records for that capability before selecting and passes the selected record's
routing identifier onward; it never widens to a bare provider key that could
resolve to a different credential.
Embedding and interactive API chat keep their existing capability-specific
transports and settings. Provider identifiers inside those protocol adapters
are transport identities, not application-level provider preferences.

Structured callers include their response contract in the prompt and validate
JSON locally. They do not require a vendor's schema-only API. Provenance records
the actual response model rather than an assumed vendor model.

Isolated text commands use a process-group deadline before the container
watchdog, with a short cleanup margin. Timing out an assessment must not stop
the run's container or make all retries fail.
The closeout assessment allows 60 seconds for CLI startup and reasoning,
within its 120-second activity budget including authentication and cleanup.
Background session summaries and error diagnosis use project-owner text routing because run cleanup can precede
those jobs. Decision drafting shares the same fallback permissions and timeout
budget as application text, including credential-specific circuit state.
Readiness reports subscriptions requiring isolation explicitly rather than
claiming standalone text is ready.

## Decisions

| Decision | Rationale | Alternative |
| --- | --- | --- |
| Reuse existing runner preferences | Keeps credentials, model policy and provider selection together | Separate provider preference per helper fragments configuration |
| Validate JSON locally | Subscription runners can perform text assessments | Requiring schema APIs excludes otherwise capable runners |
| Explicit failure without ownership | Prevents billing another tenant or silently using host credentials | Global vendor fallback hides incomplete configuration |
