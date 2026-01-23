# RDR-007: Agent CLI Abstraction (agent-harness gem)

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata
- **Date**: 2025-01-23
- **Status**: Final
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: N/A (foundational decision)
- **Related Tests**: Adapter unit tests, integration tests for each agent type

## Problem Statement

Paid needs to execute multiple AI agents (Claude Code, Cursor, Codex, GitHub Copilot) with a unified interface. Each agent has different:

1. CLI commands and flags
2. Input/output formats
3. Streaming behavior
4. Progress indicators
5. Token usage reporting
6. Error handling

Requirements:
- Uniform execution interface across all agents
- Standardized output format for metrics
- Iteration counting for guardrails
- Token usage extraction for cost tracking
- Support for both CLI and API execution modes
- Extensible for future agents

## Context

### Background

Paid is inspired by [aidp](https://github.com/viamin/aidp), which supports multiple agent providers. The key insight is that while each agent CLI has different interfaces, they all perform similar operations:
- Take a prompt and code context
- Iterate on changes
- Produce modified files
- Report usage metrics

### Technical Environment

- Agents run inside Docker containers (see RDR-004)
- API access via secrets proxy (see RDR-006)
- Ruby used for orchestration
- Agents include: Claude Code, Cursor, Codex, GitHub Copilot

## Research Findings

### Investigation Process

1. Analyzed CLI interfaces for each agent
2. Identified common patterns and outputs
3. Designed unified adapter interface
4. Evaluated API vs CLI execution modes
5. Reviewed aidp's provider abstraction

### Key Discoveries

**Agent CLI Comparison:**

| Agent | Command | Model Flag | Prompt Input | Output Format |
|-------|---------|------------|--------------|---------------|
| Claude Code | `claude-code` | `--model` | `--prompt` / stdin | Streaming text |
| Cursor | `cursor` | `--model` | `--message` | JSON events |
| Codex | `codex` | `--model` | `--task` | Streaming text |
| Copilot | `gh copilot` | N/A | Positional | Interactive |

**Output Parsing Patterns:**

Each agent reports progress differently:

```ruby
# Claude Code
"Iteration 3: Implementing feature..."
"Tokens: 5234 in, 1023 out"

# Cursor
{"type": "progress", "iteration": 3, "message": "Implementing..."}
{"type": "usage", "input_tokens": 5234, "output_tokens": 1023}

# Codex
"[Step 3/5] Writing implementation"
"API Usage: 5234 prompt tokens, 1023 completion tokens"
```

**Capability Matrix:**

| Agent | Streaming | Tool Use | Vision | Multi-file |
|-------|-----------|----------|--------|------------|
| Claude Code | Yes | Yes | Yes | Yes |
| Cursor | Yes | Yes | Yes | Yes |
| Codex | Yes | Limited | No | Yes |
| Copilot | Limited | No | No | Yes |

**API Mode:**

For simpler tasks, direct API calls via ruby-llm can replace CLI execution:

```ruby
response = RubyLLM.client.chat(
  model: "claude-3-5-sonnet",
  messages: [{ role: "user", content: prompt }],
  system: system_prompt
)
```

This is useful for:
- Planning tasks (no code execution needed)
- Model selection (meta-agent)
- Quality evaluation
- Prompt evolution

## Proposed Solution

### Approach

Create the **`agent-harness` gem** with:

1. **Unified adapter interface**: Common contract for all agents
2. **CLI adapters**: Per-agent implementations for CLI tools
3. **API adapter**: Direct LLM API calls for simpler tasks
4. **Output parser**: Standardized result format
5. **Iteration tracking**: Count iterations for guardrails
6. **Token extraction**: Extract usage for cost tracking

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        agent-harness GEM ARCHITECTURE                          │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         AgentHarness::Runner                               ││
│  │                                                                          ││
│  │  • Receives execution request (agent_type, prompt, options)             ││
│  │  • Selects appropriate adapter                                          ││
│  │  • Manages execution lifecycle                                          ││
│  │  • Returns standardized Output                                          ││
│  │                                                                          ││
│  └──────────────────────────────────┬──────────────────────────────────────┘│
│                                     │                                        │
│          ┌──────────────────────────┼──────────────────────────┐            │
│          │                          │                          │            │
│          ▼                          ▼                          ▼            │
│  ┌───────────────┐         ┌───────────────┐         ┌───────────────┐     │
│  │ ClaudeCode    │         │ Cursor        │         │ API           │     │
│  │ Adapter       │         │ Adapter       │         │ Adapter       │     │
│  │               │         │               │         │               │     │
│  │ • Build cmd   │         │ • Build cmd   │         │ • ruby-llm    │     │
│  │ • Parse output│         │ • Parse JSON  │         │ • Direct call │     │
│  │ • Track iters │         │ • Track iters │         │ • Simple tasks│     │
│  └───────────────┘         └───────────────┘         └───────────────┘     │
│          │                          │                          │            │
│          └──────────────────────────┼──────────────────────────┘            │
│                                     │                                        │
│                                     ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                       AgentHarness::Output                                 ││
│  │                                                                          ││
│  │  • success: boolean                                                     ││
│  │  • output: string (raw output)                                         ││
│  │  • iterations: integer                                                  ││
│  │  • token_usage: TokenUsage (input, output, total)                      ││
│  │  • files_changed: Array<string>                                        ││
│  │  • error: string (if failed)                                           ││
│  │  • duration_seconds: float                                              ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **Unified interface**: Simplifies workflow code (no per-agent logic)
2. **Adapter pattern**: Easy to add new agents
3. **Gem extraction**: Reusable in other projects
4. **Output normalization**: Consistent metrics across agents
5. **aidp-aligned**: Similar pattern proven in production

### Implementation Example

```ruby
# lib/paid_agents.rb
module AgentHarness
  ADAPTERS = {
    "claude_code" => ClaudeCodeAdapter,
    "cursor" => CursorAdapter,
    "codex" => CodexAdapter,
    "copilot" => CopilotAdapter,
    "api" => APIAdapter
  }.freeze

  def self.adapter_for(agent_type)
    adapter_class = ADAPTERS[agent_type.to_s]
    raise UnknownAdapterError, agent_type unless adapter_class
    adapter_class.new
  end

  def self.execute(agent_type:, prompt:, **options)
    adapter = adapter_for(agent_type)
    adapter.execute(prompt: prompt, **options)
  end
end

# lib/paid_agents/base_adapter.rb
module AgentHarness
  class BaseAdapter
    def execute(prompt:, model:, worktree_path:, **options)
      raise NotImplementedError
    end

    def available?
      raise NotImplementedError
    end

    def capabilities
      {
        supports_streaming: false,
        supports_tools: false,
        supports_vision: false,
        supports_multi_file: true
      }
    end

    protected

    def with_timing
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      [result, end_time - start_time]
    end
  end
end

# lib/paid_agents/claude_code_adapter.rb
module AgentHarness
  class ClaudeCodeAdapter < BaseAdapter
    ITERATION_PATTERN = /Iteration (\d+)/
    TOKEN_PATTERN = /Tokens: (\d+) in, (\d+) out/

    def execute(prompt:, model:, worktree_path:, **options)
      cmd = build_command(prompt, model, options)
      output, duration = with_timing do
        run_with_monitoring(cmd, worktree_path, options)
      end

      Output.new(
        success: output[:exit_status].success?,
        output: output[:stdout],
        iterations: output[:iterations],
        token_usage: output[:token_usage],
        files_changed: detect_changes(worktree_path),
        error: output[:exit_status].success? ? nil : output[:stderr],
        duration_seconds: duration
      )
    end

    def available?
      system("which claude-code > /dev/null 2>&1")
    end

    def capabilities
      {
        supports_streaming: true,
        supports_tools: true,
        supports_vision: true,
        supports_multi_file: true
      }
    end

    private

    def build_command(prompt, model, options)
      cmd = ["claude-code"]
      cmd += ["--model", model] if model
      cmd += ["--non-interactive"]
      cmd += ["--max-turns", options[:max_iterations].to_s] if options[:max_iterations]
      cmd += ["--prompt", prompt]
      cmd
    end

    def run_with_monitoring(cmd, worktree_path, options)
      iterations = 0
      token_usage = TokenUsage.new
      stdout_buffer = ""
      stderr_buffer = ""

      Open3.popen3(*cmd, chdir: worktree_path) do |stdin, stdout, stderr, wait_thr|
        stdin.close

        threads = []

        threads << Thread.new do
          stdout.each_line do |line|
            stdout_buffer += line

            # Track iterations
            if match = line.match(ITERATION_PATTERN)
              iterations = match[1].to_i
              options[:on_iteration]&.call(iterations)
            end

            # Track tokens
            if match = line.match(TOKEN_PATTERN)
              token_usage.add(match[1].to_i, match[2].to_i)
              options[:on_token_usage]&.call(token_usage)
            end

            # Heartbeat for Temporal
            options[:on_heartbeat]&.call
          end
        end

        threads << Thread.new do
          stderr_buffer = stderr.read
        end

        threads.each(&:join)
        exit_status = wait_thr.value

        {
          stdout: stdout_buffer,
          stderr: stderr_buffer,
          exit_status: exit_status,
          iterations: iterations,
          token_usage: token_usage
        }
      end
    end

    def detect_changes(worktree_path)
      result = `git -C #{worktree_path} diff --name-only HEAD`
      result.split("\n")
    end
  end
end

# lib/paid_agents/api_adapter.rb
module AgentHarness
  class APIAdapter < BaseAdapter
    def initialize(client: nil)
      @client = client || RubyLLM.client
    end

    def execute(prompt:, model:, **options)
      messages = [{ role: "user", content: prompt }]

      response, duration = with_timing do
        @client.chat(
          model: model,
          messages: messages,
          system: options[:system_prompt]
        )
      end

      Output.new(
        success: true,
        output: response.content,
        iterations: 1,
        token_usage: TokenUsage.new(
          response.usage.input_tokens,
          response.usage.output_tokens
        ),
        files_changed: [],
        duration_seconds: duration
      )
    rescue => e
      Output.new(
        success: false,
        output: "",
        iterations: 0,
        token_usage: TokenUsage.new(0, 0),
        files_changed: [],
        error: e.message,
        duration_seconds: 0
      )
    end

    def available?
      true  # Always available if API configured
    end

    def capabilities
      {
        supports_streaming: true,
        supports_tools: true,
        supports_vision: true,
        supports_multi_file: false  # API mode doesn't edit files
      }
    end
  end
end

# lib/paid_agents/output.rb
module AgentHarness
  class Output
    attr_reader :success, :output, :iterations, :token_usage,
                :files_changed, :error, :duration_seconds

    def initialize(success:, output:, iterations:, token_usage:,
                   files_changed:, error: nil, duration_seconds: 0)
      @success = success
      @output = output
      @iterations = iterations
      @token_usage = token_usage
      @files_changed = files_changed
      @error = error
      @duration_seconds = duration_seconds
    end

    def success?
      @success
    end

    def failed?
      !@success
    end

    def summary
      if success?
        "Completed in #{iterations} iterations, #{token_usage.total} tokens, " \
        "#{files_changed.size} files changed"
      else
        "Failed: #{error}"
      end
    end

    def to_h
      {
        success: success,
        output: output,
        iterations: iterations,
        token_usage: token_usage.to_h,
        files_changed: files_changed,
        error: error,
        duration_seconds: duration_seconds
      }
    end
  end

  class TokenUsage
    attr_reader :input, :output

    def initialize(input = 0, output = 0)
      @input = input
      @output = output
    end

    def add(input_tokens, output_tokens)
      @input += input_tokens
      @output += output_tokens
    end

    def total
      @input + @output
    end

    def to_h
      { input: @input, output: @output, total: total }
    end
  end
end
```

## Alternatives Considered

### Alternative 1: Direct CLI Calls in Workflow Code

**Description**: Call each agent CLI directly from Temporal activities without abstraction

**Pros**:
- Simpler initially (no abstraction layer)
- Full control over each agent

**Cons**:
- Duplicated parsing logic across activities
- Inconsistent output handling
- Harder to add new agents
- Testing complexity

**Reason for rejection**: Code duplication and inconsistency become problematic as more agents are added. Abstraction pays off quickly.

### Alternative 2: Single API-Only Approach

**Description**: Use only ruby-llm API calls, no CLI tools

**Pros**:
- Simplest architecture
- Consistent interface
- No CLI parsing complexity

**Cons**:
- Loses agent-specific features (Claude Code tools, Cursor intelligence)
- CLI tools often have better code understanding
- Some agents don't have equivalent APIs

**Reason for rejection**: CLI tools like Claude Code provide superior code editing capabilities that direct API calls can't match.

### Alternative 3: Agent-Specific Services

**Description**: Separate Rails services for each agent type

**Pros**:
- Clear separation
- Independent deployment/updates

**Cons**:
- No code reuse
- Inconsistent interfaces
- More services to maintain

**Reason for rejection**: Too much overhead for similar functionality. Adapter pattern provides cleaner separation.

### Alternative 4: Use Existing aidp Gem

**Description**: Extract and use aidp's provider abstraction directly

**Pros**:
- Already exists
- Proven in production

**Cons**:
- aidp is CLI-focused, not designed as a gem
- Would need significant refactoring
- Different design constraints

**Reason for rejection**: Better to design specifically for Paid's needs while borrowing concepts from aidp.

## Trade-offs and Consequences

### Positive Consequences

- **Unified interface**: Workflow code doesn't need agent-specific logic
- **Easy extensibility**: New agents added via new adapter class
- **Consistent metrics**: Same output format regardless of agent
- **Testability**: Adapters can be unit tested independently
- **Reusability**: Gem can be used in other projects

### Negative Consequences

- **Abstraction overhead**: Additional layer to maintain
- **Lowest common denominator**: Some agent features may not be exposed
- **Parsing fragility**: CLI output parsing can break on updates

### Risks and Mitigations

- **Risk**: Agent CLI output format changes break parsing
  **Mitigation**: Version lock agent CLIs in container image. Monitor for parsing failures. Defensive parsing with fallbacks.

- **Risk**: New agent doesn't fit adapter pattern
  **Mitigation**: Adapter interface is flexible. Can add adapter-specific extensions if needed.

## Implementation Plan

### Prerequisites

- [ ] Agent CLIs installed in container image
- [ ] ruby-llm gem available for API mode
- [ ] Container environment configured for proxy

### Step-by-Step Implementation

#### Step 1: Create Gem Structure

```bash
bundle gem agent-harness
cd agent-harness
```

#### Step 2: Implement Core Classes

- `lib/paid_agents.rb` - Main module and registry
- `lib/paid_agents/base_adapter.rb` - Abstract base
- `lib/paid_agents/output.rb` - Output and TokenUsage
- `lib/paid_agents/claude_code_adapter.rb` - Claude Code
- `lib/paid_agents/cursor_adapter.rb` - Cursor
- `lib/paid_agents/codex_adapter.rb` - Codex
- `lib/paid_agents/copilot_adapter.rb` - Copilot
- `lib/paid_agents/api_adapter.rb` - Direct API

#### Step 3: Add Tests

```ruby
# spec/paid_agents/claude_code_adapter_spec.rb
RSpec.describe AgentHarness::ClaudeCodeAdapter do
  describe "#execute" do
    it "parses iterations from output" do
      # Mock Open3.popen3 and verify parsing
    end

    it "extracts token usage" do
      # Mock output with token line
    end

    it "detects changed files" do
      # Mock git diff output
    end
  end
end
```

#### Step 4: Integrate into Paid

```ruby
# Gemfile
gem "agent-harness", path: "../agent-harness"  # Or git URL

# app/activities/agent_activities.rb
class AgentActivities
  def run_agent(agent_type:, prompt:, model:, worktree_path:, **options)
    result = AgentHarness.execute(
      agent_type: agent_type,
      prompt: prompt,
      model: model,
      worktree_path: worktree_path,
      on_heartbeat: -> { Temporalio::Activity.heartbeat },
      **options
    )

    result.to_h
  end
end
```

### Files to Create

- `agent-harness/` - Gem directory
  - `lib/paid_agents.rb`
  - `lib/paid_agents/base_adapter.rb`
  - `lib/paid_agents/output.rb`
  - `lib/paid_agents/claude_code_adapter.rb`
  - `lib/paid_agents/cursor_adapter.rb`
  - `lib/paid_agents/codex_adapter.rb`
  - `lib/paid_agents/copilot_adapter.rb`
  - `lib/paid_agents/api_adapter.rb`
  - `spec/` - Test files
  - `agent-harness.gemspec`

### Dependencies

- `ruby-llm` (~> 1.0) - For API adapter
- `open3` (stdlib) - For process execution

## Validation

### Testing Approach

1. Unit tests for each adapter (mocked execution)
2. Integration tests with real CLIs (in container)
3. Output parsing tests with sample outputs
4. Error handling tests

### Test Scenarios

1. **Scenario**: Execute Claude Code successfully
   **Expected Result**: Output with success=true, iterations counted, tokens extracted

2. **Scenario**: Execute with max iterations exceeded
   **Expected Result**: Output includes iterations up to limit

3. **Scenario**: Agent CLI not available
   **Expected Result**: `available?` returns false

4. **Scenario**: API adapter with error response
   **Expected Result**: Output with success=false, error message captured

### Performance Validation

- Adapter initialization < 1ms
- No significant overhead on CLI execution
- Streaming callbacks fire in real-time

### Security Validation

- No secrets in adapter code
- Worktree path validated before use
- Output sanitized before logging

## References

### Requirements & Standards

- Paid AGENT_SYSTEM.md - Agent execution design
- aidp provider abstraction patterns

### Dependencies

- [ruby-llm](https://github.com/codenamev/ruby-llm) - LLM client
- Agent CLI documentation (Anthropic, Cursor, OpenAI, GitHub)

### Research Resources

- aidp provider implementation
- Adapter pattern (Gang of Four)
- Ruby gem best practices

## Notes

- Consider adding adapter for local models (Ollama) in future
- May need version-specific parsing for different CLI versions
- Output format standardization enables unified metrics dashboard
- Gem could be open-sourced for community benefit
