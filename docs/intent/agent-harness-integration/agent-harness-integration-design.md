---
parent: PAID
prefix: AGENT-HARNESS
---

# Low-Level Design: AgentHarness Integration

> Companion to [`docs/high-level-design.md`](../../high-level-design.md) and
> [RDR-007](../../rdrs/RDR-007-agent-cli-abstraction.md). This LLD documents
> the shipped boundary between Paid and `agent_harness`.

## Purpose

Paid delegates application-level agent and LLM execution to `agent_harness`
instead of maintaining provider-specific command builders, API clients, or
execution result parsers in the control plane. The integration boundary must
stay narrow enough that provider churn is absorbed in `agent_harness`, while
Paid still controls container isolation, run state, and audit persistence.

## Runtime Contract

### Execution planning

`Runners::HarnessExecutionPlan` is the app-level adapter from Paid runner
records and runner keys to `agent_harness` providers. It:

- resolves the harness provider class from the runner key,
- builds the provider config through `AgentHarness.build_config`,
- forces `externally_sandboxed = true` because execution already happens in the
  agent container,
- and returns the harness plan payload (`command`, `env`, `preparation`) as the
  contract Paid uses for container execution.

This contract is used both for persisted `Runner` records and for app-level
runner keys that do not require a per-user `Runner` row.

### Direct-outbound credential isolation

Provisioning seeds baseline container env with Paid secrets-proxy credentials
(per-run proxy tokens and proxy base URLs for each provider family). A
direct-outbound runtime — e.g. OpenCode configured with a user provider API
key — talks to the upstream provider directly, so those proxy credentials are
unused and must not ride along in the runner process environment.
`Runner#opencode_direct_outbound_unset_env` lists the proxy-credential
variables to unset, minus whatever the runtime itself sets for the selected
provider (the real upstream key and base URL), so the runner process carries
only provider credentials that are actually its own.

### Container execution

`Containers::HarnessExecutor` is the execution-side adapter. It takes the
planned harness command and runs it through `AgentRun#execute_in_container`,
preserving the command, environment, and any `AgentHarness::ExecutionPreparation`
file writes while translating the container result back into
`AgentHarness::CommandExecutor::Result`.

Paid owns the container boundary; `agent_harness` owns provider-specific command
shape and response normalization.

### LLM selection calls

When Paid needs an application-level LLM decision outside the main coding run,
it still routes through `agent_harness`. `Models::MetaAgentSelector` is the
representative path here: it calls `AgentHarness.send_message` for model
selection instead of issuing raw provider HTTP calls.

## Accepted Divergence

RDR-007's older "out of scope" note about API-only planning/evaluation paths is
stale. Current Paid guidance routes application-level LLM calls through
`agent_harness`, with the secrets proxy remaining the infrastructure exception
for container-authenticated traffic.

## References

- `app/services/runners/harness_execution_plan.rb`
- `app/services/containers/harness_executor.rb`
- `app/services/models/meta_agent_selector.rb`
