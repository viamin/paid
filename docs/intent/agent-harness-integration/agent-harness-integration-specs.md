# EARS Specs: AgentHarness Integration

> Testable claims for Paid's `agent_harness` integration boundary.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **AGENT-HARNESS-001** — When Paid builds an execution plan for a runner
  or runner key, the system SHALL delegate provider planning to
  `agent_harness` and mark the provider config as externally sandboxed because
  the agent container is the sandbox boundary.
  *Code:* `Runners::HarnessExecutionPlan`.

- [x] **AGENT-HARNESS-002** — When Paid executes a planned harness command, the
  system SHALL run it through `AgentRun#execute_in_container` and translate the
  result back into `AgentHarness::CommandExecutor::Result`, preserving command,
  env, and preparation data.
  *Code:* `Containers::HarnessExecutor`.

- [x] **AGENT-HARNESS-003** — When Paid performs an application-level LLM model
  selection, the system SHALL call `AgentHarness.send_message` rather than a
  raw provider API client.
  *Code:* `Models::MetaAgentSelector`.

- [x] **AGENT-HARNESS-004** — When a direct-outbound runner runtime (e.g.
  OpenCode with a user provider API key) is planned for container execution,
  the system SHALL strip the Paid secrets-proxy credentials seeded as baseline
  container env from that runtime's process environment, keeping only the
  variables the runtime itself sets for the selected upstream provider.
  *Tests:* `spec/models/runner_spec.rb`,
  `spec/services/runners/harness_execution_plan_spec.rb`.
  *Code:* `Runner#opencode_direct_outbound_unset_env`.
