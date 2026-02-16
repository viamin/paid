# Task: Integrate agent-harness container executor into Paid

## Context

We filed viamin/agent-harness#15 to add Docker container execution support to the
agent-harness gem. The PR implementing that feature is pasted below for reference.

**Your task**: Update the Paid codebase to use the new agent-harness container
execution support, replacing the current direct Docker exec workaround.

## Background

Agents in Paid run inside isolated Docker containers. We recently fixed a critical
bug where the agent CLI was executing on the host (devcontainer) instead of inside
the container, causing commits to land on the wrong git branch.

The current workaround in `RunAgentActivity` bypasses `AgentHarness` entirely and
calls `container_service.execute()` (Docker API) directly. This works for isolation
but loses agent-harness orchestration features: circuit breakers, retries, rate
limiting, provider fallback, error classification, and token tracking.

## Current State (what to change)

### 1. `app/temporal/activities/run_agent_activity.rb`

Currently builds the CLI command manually and executes via Docker API:

```ruby
AGENT_COMMANDS = {
  "claude_code" => %w[claude --print --output-format=text --dangerously-skip-permissions -p]
}.freeze

def run_agent_in_container(agent_run, prompt)
  container_service = reconnect_container(agent_run)
  command = AGENT_COMMANDS[agent_run.agent_type] + [ prompt ]
  result = container_service.execute(command, timeout: agent_timeout)
  # ...
end
```

This should be replaced with `AgentHarness.send_message()` using a container-aware
executor, so all 8 agent types work and orchestration features are preserved.

### 2. `app/services/agent_runs/execute.rb`

The `AgentRuns::Execute` service calls `AgentHarness.send_message()` with the host
executor. It handles status updates, logging, token tracking, and error
classification. This service should be reused (or extended) for container execution
rather than duplicating its logic in `RunAgentActivity`.

Key method:
```ruby
def execute_agent
  AgentHarness.send_message(prompt, provider: provider_name, dangerous_mode: true)
end
```

This needs to accept or construct a container-aware executor for the given agent run.

### 3. `config/initializers/agent_harness.rb`

Currently configures a global `AgentHarness` with the default (local) executor.
The container executor is per-request (different container per agent run), so the
integration needs to handle per-request executor injection rather than changing the
global config.

### 4. `app/services/containers/provision.rb`

The `Containers::Provision` service provides `execute(command, timeout:, stream:)`
which runs commands inside a container via Docker API. The new agent-harness executor
needs to delegate to this. Key interface:

- Input: `command` (Array or String), `timeout:` (Integer), `stream:` (Boolean)
- Output: `Result` with `success?`, `[:stdout]`, `[:stderr]`, `[:exit_code]`
- Errors: `TimeoutError`, `ExecutionError`, `ProvisionError`

## Requirements

1. **Replace the workaround**: `RunAgentActivity` should use `AgentHarness` (via
   `AgentRuns::Execute` or similar) with the container executor, not direct Docker
   exec. Remove `AGENT_COMMANDS` constant — let agent-harness providers build their
   own commands.

2. **Per-request executor**: Each agent run uses a different container, so the
   executor must be constructed per-request with the specific `container_service`.
   Don't change the global `AgentHarness` configuration.

3. **Preserve orchestration**: The integration should get circuit breakers, retries,
   rate limiting, error classification, and token tracking from agent-harness.

4. **Support all agent types**: The current workaround only supports `claude_code`.
   Using agent-harness providers restores support for all 8 agent types (claude_code,
   cursor, codex, copilot, aider, gemini, opencode, kilocode).

5. **Bridge the Result types**: `Containers::Provision::Result` has `[:stdout]`,
   `[:stderr]`, `[:exit_code]`. The agent-harness `CommandExecutor::Result` has
   `.stdout`, `.stderr`, `.exit_code`. The adapter/executor needs to bridge these.

6. **Update specs**: Update `spec/temporal/activities/run_agent_activity_spec.rb`
   and `spec/services/agent_runs/execute_spec.rb` to cover container execution.

7. **Run linters and tests**: Ensure `bin/rubocop` and `bin/rspec` pass.

## Approach suggestion

The cleanest approach is likely:

1. Create a `ContainerCommandExecutor` class (in `app/services/containers/` or
   `lib/`) that wraps `Containers::Provision#execute` with the
   `AgentHarness::CommandExecutor` interface.

2. Modify `AgentRuns::Execute` to accept an optional `executor:` parameter. When
   provided, configure agent-harness to use it for that request.

3. Update `RunAgentActivity` to construct a `ContainerCommandExecutor` from the
   agent run's container and pass it through `AgentRuns::Execute`.

## agent-harness PR for reference

https://github.com/viamin/agent-harness/pull/16
