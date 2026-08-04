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
