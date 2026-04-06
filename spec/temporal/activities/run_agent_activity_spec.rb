# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RunAgentActivity do
  let(:activity) { described_class.new }
  let(:user) { create(:user) }
  let(:project) { create(:project, account: user.account, created_by: user) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) { create(:agent_run, :with_git_context, project: project, issue: issue, container_id: "abc123") }
  let(:container_service) { instance_double(Containers::Provision) }
  let(:git_ops) { instance_double(Containers::GitOperations) }
  let(:exec_success) { Containers::Provision::Result.success(stdout: "Done", stderr: "", exit_code: 0) }
  let(:exec_failure) { Containers::Provision::Result.failure(error: "exit 1", stdout: "", stderr: "error", exit_code: 1) }

  before do
    # Ensure fallback is disabled by default so tests behave like single-provider runs
    user.settings.update!(fallback_enabled: false)

    # Stub github_client so effective_prompt → prompt_for_issue → BuildForIssue
    # does not make real HTTP calls (blocked by WebMock).
    github_client = instance_double(GithubClient, issue_comments: [])
    allow(project.github_token).to receive(:client).and_return(github_client)

    allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
    allow(Containers::Provision).to receive(:reconnect)
      .with(agent_run: agent_run, container_id: "abc123")
      .and_return(container_service)
    allow(Containers::GitOperations).to receive(:new)
      .with(container_service: container_service, agent_run: agent_run)
      .and_return(git_ops)
  end

  describe "#with_periodic_heartbeat" do
    let(:mock_context) { instance_double(Temporalio::Activity::Context) }

    before do
      allow(mock_context).to receive(:heartbeat)
    end

    it "yields the block and returns its result" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)

      result = activity.send(:with_periodic_heartbeat, "test", interval: 0.01) { 42 }

      expect(result).to eq(42)
    end

    it "emits heartbeats while the block is running" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)

      activity.send(:with_periodic_heartbeat, "test", interval: 0.05) do
        sleep 0.15
        :done
      end

      expect(mock_context).to have_received(:heartbeat).with("test").at_least(:once)
    end

    it "propagates exceptions from the block with original backtrace" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)

      expect {
        activity.send(:with_periodic_heartbeat, "test", interval: 0.01) do
          raise ArgumentError, "boom"
        end
      }.to raise_error(ArgumentError, "boom") { |e|
        # Thread#value preserves the original backtrace from inside the
        # worker thread rather than replacing it with this call site.
        expect(e.backtrace.first).to include("run_agent_activity_spec.rb")
      }
    end

    it "yields without heartbeating when outside activity context" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(nil)

      result = activity.send(:with_periodic_heartbeat, "test") { 99 }

      expect(result).to eq(99)
    end

    it "re-raises CanceledError from heartbeat" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)
      allow(mock_context).to receive(:heartbeat).and_raise(Temporalio::Error::CanceledError, "canceled")

      expect {
        activity.send(:with_periodic_heartbeat, "test", interval: 0.01) do
          sleep 0.05
          :done
        end
      }.to raise_error(Temporalio::Error::CanceledError)
    end

    it "raises InfiniteLoopError when a loop is detected" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)

      loop_result = AgentRuns::DetectInfiniteLoop::Result.new(detected: true, reason: "test loop")
      allow(AgentRuns::DetectInfiniteLoop).to receive(:call).and_return(loop_result)

      expect {
        activity.send(:with_periodic_heartbeat, "test", interval: 0.01, agent_run: agent_run) do
          sleep 0.2
          :done
        end
      }.to raise_error(described_class::InfiniteLoopError, "test loop")
    end

    it "does not raise when no infinite loop is detected" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)

      no_loop_result = AgentRuns::DetectInfiniteLoop::Result.new(detected: false)
      allow(AgentRuns::DetectInfiniteLoop).to receive(:call).and_return(no_loop_result)

      result = activity.send(:with_periodic_heartbeat, "test", interval: 0.01, agent_run: agent_run) do
        sleep 0.05
        42
      end

      expect(result).to eq(42)
    end
  end

  describe "AGENT_COMMANDS" do
    it "includes a command mapping for codex" do
      expect(described_class::AGENT_COMMANDS).to have_key("codex")
      expect(described_class::AGENT_COMMANDS["codex"]).to include("codex")
    end

    it "includes upstream sandbox bypass flags for codex" do
      cmd = described_class::AGENT_COMMANDS["codex"]
      expect(cmd).to start_with("codex", "exec", "--dangerously-bypass-approvals-and-sandbox")
      expect(cmd).to include("--")
    end

    it "includes a command mapping for gemini" do
      expect(described_class::AGENT_COMMANDS).to have_key("gemini")
      expect(described_class::AGENT_COMMANDS["gemini"]).to include("gemini")
    end

    it "includes a command mapping for kilocode" do
      expect(described_class::AGENT_COMMANDS).to have_key("kilocode")
      expect(described_class::AGENT_COMMANDS["kilocode"]).to include("kilo")
    end

    it "includes a command mapping for opencode" do
      expect(described_class::AGENT_COMMANDS).to have_key("opencode")
      expect(described_class::AGENT_COMMANDS["opencode"]).to eq(%w[opencode run])
    end

    it "includes a command mapping for copilot" do
      expect(described_class::AGENT_COMMANDS).to have_key("copilot")
      expect(described_class::AGENT_COMMANDS["copilot"]).to include("github-copilot-cli")
    end
  end

  describe ".provider_order" do
    it "returns only the primary provider when fallback is disabled" do
      result = described_class.provider_order(
        agent_type: "claude_code",
        fallback_enabled: false,
        fallback_providers: %w[cursor aider]
      )

      expect(result).to eq([ "claude_code" ])
    end

    it "deduplicates canonical providers in fallback order" do
      result = described_class.provider_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_providers: %w[claude cursor aider]
      )

      expect(result).to eq(%w[claude_code cursor aider])
    end

    it "includes codex in fallback order when listed" do
      result = described_class.provider_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_providers: %w[codex cursor]
      )

      expect(result).to eq(%w[claude_code codex cursor])
    end

    it "includes gemini in fallback order when listed" do
      result = described_class.provider_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_providers: %w[gemini codex]
      )

      expect(result).to eq(%w[claude_code gemini codex])
    end

    it "includes kilocode in fallback order when listed" do
      result = described_class.provider_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_providers: %w[kilocode codex]
      )

      expect(result).to eq(%w[claude_code kilocode codex])
    end

    it "includes opencode in fallback order when listed" do
      result = described_class.provider_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_providers: %w[opencode codex]
      )

      expect(result).to eq(%w[claude_code opencode codex])
    end

    it "includes copilot in fallback order when listed" do
      result = described_class.provider_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_providers: %w[copilot codex]
      )

      expect(result).to eq(%w[claude_code copilot codex])
    end
  end

  describe ".provider_attempt_count" do
    it "matches provider_order size for deduplicated fallback providers" do
      count = described_class.provider_attempt_count(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_providers: %w[claude cursor aider]
      )

      expect(count).to eq(3)
    end
  end

  describe "#build_command" do
    it "builds a sh -c wrapper for Codex subscription auth" do
      context = described_class::CommandContext.new(
        provider_candidate: "codex",
        provider: "codex",
        command_prefix: described_class::AGENT_COMMANDS["codex"],
        user: nil
      )
      command = activity.send(:build_command, context, "say 'hi'")
      script = command[2]
      codex_command = described_class::AGENT_COMMANDS.fetch("codex").join(" ")

      expect(command[0..1]).to eq(%w[sh -c])
      expect(script).to include('if [ "$PAID_CODEX_SUBSCRIPTION_AUTH" = "1" ]')
      expect(script).to include("-u OPENAI_API_KEY")
      expect(script).to include(codex_command)
      expect(command[3]).to eq("--")
      expect(command[4]).to eq("say 'hi'")
    end

    it "builds a sh -c wrapper for Gemini subscription auth" do
      context = described_class::CommandContext.new(
        provider_candidate: "gemini",
        provider: "gemini",
        command_prefix: described_class::AGENT_COMMANDS["gemini"],
        user: nil
      )
      command = activity.send(:build_command, context, "say 'hi'")
      script = command[2]

      expect(command[0..1]).to eq(%w[sh -c])
      expect(script).to include('if [ "$PAID_GEMINI_SUBSCRIPTION_AUTH" = "1" ]')
      expect(script).to include("-u GEMINI_API_KEY")
      expect(script).to include("-u GOOGLE_GEMINI_BASE_URL")
      expect(script).to include("gemini -y -p")
      expect(command[3]).to eq("--")
      expect(command[4]).to eq("say 'hi'")
    end

    it "preserves multi-line prompts as a positional parameter" do
      multiline_prompt = "First line\nSecond line\n  indented third"
      context = described_class::CommandContext.new(
        provider_candidate: "codex",
        provider: "codex",
        command_prefix: described_class::AGENT_COMMANDS["codex"],
        user: nil
      )
      command = activity.send(:build_command, context, multiline_prompt)

      expect(command[4]).to eq(multiline_prompt)
      expect(command[2]).not_to include("\n")
    end

    it "keeps non-subscription providers in array form" do
      context = described_class::CommandContext.new(
        provider_candidate: "claude",
        provider: "claude",
        command_prefix: described_class::AGENT_COMMANDS["claude"],
        user: nil
      )
      command = activity.send(:build_command, context, "ping")

      expect(command).to eq(described_class::AGENT_COMMANDS["claude"] + [ "ping" ])
    end

    it "uses canonical provider state keys for subscription entries" do
      subscription_provider = user.providers.find_by!(provider_key: "claude")
      state_key = activity.send(:state_key_for, subscription_provider.routing_key, "claude", user)

      expect(state_key).to eq("claude")
    end

    context "with a direct-outbound OpenCode provider" do
      it "passes config via exec env instead of embedding it in the command" do
        opencode_context = build_opencode_context(user)
        command = activity.send(:build_command, opencode_context, "ping")
        env = activity.send(:command_env_for, opencode_context)

        expect(command[2]).to include('printf \'%s\' "$PAID_OPENCODE_CONFIG_B64" | base64 -d')
        expect(command[2]).to include('opencode run "$1"')
        expect(command[2]).not_to include('\$1')
        expect(command[2]).not_to include("sk-openrouter-secret")
        expect(Base64.strict_decode64(env.fetch("PAID_OPENCODE_CONFIG_B64"))).to include("sk-openrouter-secret")
      end
    end
  end

  describe "#provider_entry_for" do
    it "memoizes routing-key lookups per user and identifier" do
      provider = create(:provider, user: user, provider_key: "opencode")

      expect(Provider).to receive(:for_identifier).once.with(user, provider.routing_key).and_call_original

      2.times do
        expect(activity.send(:provider_entry_for, provider.routing_key, user)).to eq(provider)
      end
    end
  end

  describe "#build_provider_order" do
    it "preserves routing-key fallback entries for agent-type runs" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
      opencode_provider = create_opencode_provider_entry(
        user: user,
        api_key: api_key,
        name: "Kimi K2.5",
        model: "moonshotai/kimi-k2-0905"
      )
      user.settings.update!(fallback_enabled: true, fallback_providers: [ opencode_provider.routing_key ])

      providers = activity.send(:build_provider_order, agent_run, user.settings)

      expect(providers).to eq([ "claude_code", opencode_provider.routing_key ])
    end
  end

  def build_opencode_context(user)
    api_key = create(:provider_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret")
    provider = create_opencode_provider_entry(user: user, api_key: api_key, name: nil, model: "moonshotai/kimi-k2-0905")

    described_class::CommandContext.new(
      provider_candidate: provider.routing_key,
      provider: "opencode",
      command_prefix: described_class::AGENT_COMMANDS["opencode"],
      user: user
    )
  end

  def expect_opencode_fallback_execution(opencode_provider)
    call_count = 0
    expect(container_service).to receive(:execute).twice do |command, **opts|
      call_count += 1
      if call_count == 1
        rate_limit_failure
      else
        expect(command[0..1]).to eq(%w[sh -lc])
        expect(command[2]).to include('printf \'%s\' "$PAID_OPENCODE_CONFIG_B64" | base64 -d')
        expect(command[2]).to include('opencode run "$1"')
        expect(opts[:env]).to include("PAID_OPENCODE_CONFIG_B64")
        exec_success
      end
    end

    result = activity.execute(agent_run_id: agent_run.id)

    expect(result[:success]).to be true
    expect(result[:final_provider]).to eq(opencode_provider.routing_key)
    expect(agent_run.reload.final_provider).to eq(opencode_provider.routing_key)
  end

  def create_opencode_provider_entry(user:, api_key:, name:, model:)
    create(
      :provider,
      user: user,
      provider_key: "opencode",
      auth_type: "api_key",
      provider_api_key: api_key,
      name: name || "",
      enabled_for_agent_runs: true,
      config: { "opencode" => { "api_provider" => "openrouter", "model" => model } }
    )
  end

  describe "#execute" do
    context "when agent succeeds in container" do
      before do
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "pre_agent_sha_abc123", commit_uncommitted_changes: false)
      end

      it "executes the agent CLI inside the container" do
        allow(git_ops).to receive(:has_changes_since?).and_return(false)

        expect(container_service).to receive(:execute).with(
          array_including("claude", "--print", "--output-format=text", "--dangerously-skip-permissions", "-p"),
          hash_including(timeout: anything)
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "captures HEAD SHA before running the agent" do
        allow(git_ops).to receive(:has_changes_since?).and_return(false)

        expect(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")

        activity.execute(agent_run_id: agent_run.id)
      end

      it "starts the agent run before execution" do
        allow(git_ops).to receive(:has_changes_since?).and_return(false)

        activity.execute(agent_run_id: agent_run.id)

        expect(agent_run.reload.status).to eq("running")
      end

      it "returns has_changes: true when agent made new commits" do
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(true)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(result[:success]).to be true
      end

      it "returns has_changes: false when agent made no changes" do
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be false
        expect(result[:success]).to be true
      end

      it "succeeds and logs an informational message when provider has no output and no changes" do
        no_output_success = Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0)
        allow(container_service).to receive(:execute).and_return(no_output_success)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
        expect(result[:has_changes]).to be false
        expect(agent_run.reload.agent_run_logs.where(
          log_type: "system",
          content: "Provider completed with no output and no changes"
        )).to exist
      end

      it "succeeds when provider output is binary encoded" do
        binary_success = Containers::Provision::Result.success(
          stdout: "Done \xFF".b,
          stderr: "",
          exit_code: 0
        )
        allow(container_service).to receive(:execute).and_return(binary_success)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
        expect(result[:final_provider]).to eq("claude_code")
        expect(agent_run.reload.final_provider).to eq("claude_code")
        expect(agent_run.providers_attempted.map { |attempt| attempt["provider"] }).to eq([ "claude_code" ])
      end

      it "returns has_changes: false when container check fails" do
        allow(git_ops).to receive(:has_changes_since?).and_raise(StandardError, "container gone")

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be false
      end

      it "auto-commits uncommitted changes after agent runs" do
        allow(git_ops).to receive(:has_changes_since?).and_return(true)

        expect(git_ops).to receive(:commit_uncommitted_changes).and_return(true)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "falls back to has_changes? when pre_agent_sha capture fails" do
        allow(git_ops).to receive(:head_sha).and_raise(StandardError, "container not ready")
        allow(git_ops).to receive_messages(commit_uncommitted_changes: false, has_changes?: true)
        allow(git_ops).to receive(:has_changes_since?)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(git_ops).not_to have_received(:has_changes_since?)
      end

      it "records the final_provider on success" do
        allow(git_ops).to receive(:has_changes_since?).and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:final_provider]).to eq("claude_code")
        expect(agent_run.reload.final_provider).to eq("claude_code")
      end
    end

    context "when agent fails in container" do
      before do
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute).and_return(exec_failure)
      end

      it "raises AllProvidersExhausted when all providers fail" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
      end

      it "marks the agent run as failed" do
        begin
          activity.execute(agent_run_id: agent_run.id)
        rescue Temporalio::Error::ApplicationError
          # expected
        end

        expect(agent_run.reload.status).to eq("failed")
      end
    end

    context "when agent hits rate limit (single provider)" do
      let(:rate_limit_output) do
        Containers::Provision::Result.failure(
          error: "rate limit", stdout: "",
          stderr: "You're out of extra usage \u00b7 resets 5am (UTC)", exit_code: 1
        )
      end

      def expect_prompt_echo_to_fail_without_rate_limit!(prompt:, output:)
        allow(agent_run).to receive(:effective_prompt).and_return(prompt)
        allow(container_service).to receive(:execute).and_return(output)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload

        expect(agent_run.status).to eq("failed")
        expect(agent_run.error_message).to include("All providers exhausted")
        expect(agent_run.error_message).not_to include("rate limited")

        provider_state = user.provider_states.find_by(provider_name: "claude")
        expect(provider_state&.rate_limited_until).to be_nil
      end

      before do
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute).and_return(rate_limit_output)
      end

      it "marks the agent run as rate_limited" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.rate_limited_until).to be_present
        expect(agent_run.error_message).to include("rate limited")
      end

      it "detects Claude-specific usage limit error" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        expect(agent_run.reload.status).to eq("rate_limited")
      end

      it "marks the agent run as rate_limited when provider output is binary encoded" do
        binary_rate_limit_output = Containers::Provision::Result.failure(
          error: "rate limit",
          stdout: "",
          stderr: "You're out of extra usage \xB7 resets 5am (UTC)".b,
          exit_code: 1
        )
        allow(container_service).to receive(:execute).and_return(binary_rate_limit_output)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.rate_limited_until).to be_present
        expect(agent_run.error_message).to include("rate limited")
      end

      it "does not classify echoed prompt text as a rate limit" do
        echoed_prompt = <<~PROMPT
          Investigate why the secrets proxy returns 429 for token usage limits.
          Confirm whether the provider itself is actually rate limited.
        PROMPT
        prompt_echo_output = Containers::Provision::Result.failure(
          error: "killed", stdout: "", stderr: echoed_prompt, exit_code: 137
        )

        expect_prompt_echo_to_fail_without_rate_limit!(prompt: echoed_prompt, output: prompt_echo_output)
      end

      it "ignores prompt echoes wrapped in common prefixes" do
        echoed_prompt = <<~PROMPT
          Investigate why the secrets proxy returns 429 for token usage limits.
          Confirm whether the provider itself is actually rate limited.
        PROMPT
        prefixed_prompt_echo_output = Containers::Provision::Result.failure(
          error: "killed",
          stdout: "",
          stderr: <<~OUTPUT,
            user
            > Investigate why the secrets proxy returns 429 for token usage limits.
            > Confirm whether the provider itself is actually rate limited.
          OUTPUT
          exit_code: 137
        )

        expect_prompt_echo_to_fail_without_rate_limit!(prompt: echoed_prompt, output: prefixed_prompt_echo_output)
      end
    end

    context "when agent times out (wall clock)" do
      before do
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute)
          .and_raise(Containers::Provision::TimeoutError)
      end

      it "raises AllProvidersExhausted after timeout" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
      end

      it "marks the agent run as timed out with wall_clock type" do
        begin
          activity.execute(agent_run_id: agent_run.id)
        rescue Temporalio::Error::ApplicationError
          # expected
        end

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("wall_clock_timeout")
      end

      it "enqueues ProcessRunQueueJob" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError)
          .and have_enqueued_job(ProcessRunQueueJob)
      end
    end

    context "when agent hits startup timeout" do
      before do
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute)
          .and_raise(Containers::Provision::StartupTimeoutError)
      end

      it "marks the agent run as timed out with startup type" do
        begin
          activity.execute(agent_run_id: agent_run.id)
        rescue Temporalio::Error::ApplicationError
          # expected
        end

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("startup_timeout")
      end

      it "raises AllProvidersExhausted" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
      end
    end

    context "when agent hits idle timeout" do
      before do
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute)
          .and_raise(Containers::Provision::IdleTimeoutError)
      end

      it "marks the agent run as timed out with idle type" do
        begin
          activity.execute(agent_run_id: agent_run.id)
        rescue Temporalio::Error::ApplicationError
          # expected
        end

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("idle_timeout")
      end

      it "raises AllProvidersExhausted" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
      end
    end

    context "when no container is provisioned" do
      it "raises an ApplicationError" do
        other_issue = create(:issue, project: project)
        run_no_container = create(:agent_run, :with_git_context, project: project, issue: other_issue, container_id: nil)
        allow(AgentRun).to receive(:find).with(run_no_container.id).and_return(run_no_container)

        expect {
          activity.execute(agent_run_id: run_no_container.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /No container provisioned/)
      end
    end

    it "raises an error when no prompt is available" do
      agent_run_no_prompt = create(:agent_run, :with_custom_prompt, project: project, container_id: "abc123")
      allow(agent_run_no_prompt).to receive(:effective_prompt).and_return(nil)
      allow(AgentRun).to receive(:find).with(agent_run_no_prompt.id).and_return(agent_run_no_prompt)

      expect {
        activity.execute(agent_run_id: agent_run_no_prompt.id)
      }.to raise_error(Temporalio::Error::ApplicationError, /No prompt available/)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      allow(AgentRun).to receive(:find).and_call_original

      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises for unsupported agent types" do
      unsupported_issue = create(:issue, project: project)
      unsupported_run = create(:agent_run, project: project, issue: unsupported_issue,
        agent_type: "api", container_id: "abc123")
      allow(AgentRun).to receive(:find).with(unsupported_run.id).and_return(unsupported_run)
      allow(Containers::Provision).to receive(:reconnect)
        .with(agent_run: unsupported_run, container_id: "abc123")
        .and_return(container_service)
      allow(Containers::GitOperations).to receive(:new)
        .with(container_service: container_service, agent_run: unsupported_run)
        .and_return(git_ops)
      allow(git_ops).to receive(:head_sha).and_return("sha123")

      expect {
        activity.execute(agent_run_id: unsupported_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
    end

    context "when goal is create_issue" do
      let(:agent_run) do
        create(:agent_run, :create_issue_goal, :with_git_context,
          project: project, container_id: "abc123")
      end

      before do
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)
      end

      it "uses the shorter issue goal timeout" do
        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(
            timeout: described_class::DEFAULT_ISSUE_GOAL_TIMEOUT,
            idle_timeout: described_class::DEFAULT_ISSUE_GOAL_IDLE_TIMEOUT,
            env: {}
          )
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "includes curl timeouts in the augmented prompt" do
        expect(container_service).to receive(:execute) do |command, **_opts|
          prompt = command.last
          expect(prompt).to include("--connect-timeout 10")
          expect(prompt).to include("--max-time 30")
          exec_success
        end

        activity.execute(agent_run_id: agent_run.id)
      end
    end

    context "when goal is create_pr" do
      it "uses the default agent timeout without idle_timeout" do
        project.update!(max_execution_seconds: 86_400)
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(
            timeout: AGENT_TIMEOUT_DEFAULT,
            idle_timeout: nil,
            env: {}
          )
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end
    end

    context "with fallback enabled" do
      let(:rate_limit_failure) do
        Containers::Provision::Result.failure(
          error: "rate limit", stdout: "", stderr: "rate limit exceeded", exit_code: 1
        )
      end

      before do
        allow(ProviderSupport).to receive(:container_executable_provider_keys).and_return(%w[claude cursor aider])
        user.providers.find_or_create_by!(provider_key: "cursor")
        user.providers.find_or_create_by!(provider_key: "aider")
        user.settings.update!(fallback_enabled: true, fallback_providers: %w[claude cursor aider])
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)
      end

      it "falls back to next provider on rate limit" do
        call_count = 0
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          call_count += 1
          if call_count == 1
            rate_limit_failure
          else
            exec_success
          end
        end

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
        expect(result[:final_provider]).to eq("cursor")
      end

      it "includes configured fallback-only providers even when saved fallback order is empty" do
        user.providers.find_by!(provider_key: "cursor").update!(
          enabled_for_agent_runs: false,
          enabled_for_fallback: true
        )
        user.settings.update!(fallback_enabled: true, fallback_providers: [])

        call_count = 0
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          call_count += 1
          if call_count == 1
            rate_limit_failure
          else
            exec_success
          end
        end

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
        expect(result[:final_provider]).to eq("aider")
      end

      it "records provider switch when falling back" do
        call_count = 0
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          call_count += 1
          if call_count == 1
            rate_limit_failure
          else
            exec_success
          end
        end

        activity.execute(agent_run_id: agent_run.id)

        expect(agent_run.reload.provider_switches).to eq(1)
      end

      it "does not continue to the next provider when the first provider times out" do
        allow(container_service).to receive(:execute)
          .and_raise(Containers::Provision::TimeoutError, "took too long")

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
          .and have_enqueued_job(ProcessRunQueueJob)

        agent_run.reload

        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("wall_clock_timeout")
        expect(agent_run.providers_attempted.map { |attempt| attempt["provider"] }).to eq([ "claude_code" ])
        expect(agent_run.final_provider).to be_nil
      end

      it "reclassifies timeout output that contains quota errors as rate limited" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stderr", "Error: Free tier limit reached. Please upgrade to a paid plan to continue using the service.")
          3.times { |index| agent_run.log!("stdout", "still waiting on provider chunk #{index}") }
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.providers_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "reclassifies timeout output as rate limited even when the quota message appears before later output" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stderr", "Free tier limit reached. Please upgrade for higher usage.")
          250.times { |index| agent_run.log!("stdout", "provider still warming up: #{index}") }
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.providers_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "reclassifies timeout output as rate limited when the quota signal spans chunk boundaries" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stderr", "Free tier")
          agent_run.log!("stderr", " limit reached while processing request")
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.providers_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "does not reclassify timeouts when recent output only mentions rate limits conversationally" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stdout", "Document how to handle a service overloaded response and a server at capacity banner in the retry guide.")
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
          .and have_enqueued_job(ProcessRunQueueJob)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("idle_timeout")
        expect(agent_run.providers_attempted.first["error_type"]).to eq("timeout")
      end

      it "preserves timeout handling when the timeout happens before provider execution starts" do
        allow(activity).to receive(:augment_prompt_for_goal)
          .and_raise(Containers::Provision::TimeoutError, "took too long before exec")

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
          .and have_enqueued_job(ProcessRunQueueJob)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("wall_clock_timeout")
      end

      it "raises AllProvidersExhausted when all fallbacks fail" do
        allow(container_service).to receive(:execute).and_return(exec_failure)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
      end

      it "marks run as rate_limited when all providers hit rate limits" do
        allow(container_service).to receive(:execute).and_return(rate_limit_failure)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
      end

      it "classifies 'exhausted ... capacity' as a rate limit" do
        gemini_rate_limit = Containers::Provision::Result.failure(
          error: "exit 1", stdout: "", stderr: "You have exhausted your capacity on this model.", exit_code: 1
        )
        allow(container_service).to receive(:execute).and_return(gemini_rate_limit)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.rate_limited_until).to be_present
      end

      it "logs rate-limit fallback availability using the canonical provider key" do
        logger = instance_double(ActiveSupport::Logger, info: nil, warn: nil, error: nil)
        allow(activity).to receive(:logger).and_return(logger)
        allow(UserSetting).to receive(:rate_limit_fallback_providers).with(user).and_return([ "claude" ])
        allow(container_service).to receive(:execute).and_return(rate_limit_failure)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        expect(logger).to have_received(:info).with(
          message: "agent_execution.rate_limit_fallback_available",
          provider: "claude",
          agent_run_id: agent_run.id
        )
      end

      it "uses provider display names in exhausted-provider labels" do
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
        kimi = create_opencode_provider_entry(user: user, api_key: api_key, name: "Kimi K2.5", model: "moonshotai/kimi-k2-0905")
        opus = create_opencode_provider_entry(user: user, api_key: api_key, name: "Opus via OpenCode", model: "anthropic/claude-opus-4.1")

        labels = activity.send(:provider_attempt_labels, [ kimi.routing_key, opus.routing_key ], agent_run, user)

        expect(labels).to eq([ "Kimi K2.5", "Opus via OpenCode" ])
      end

      it "executes routing-key fallbacks with the provider entry config intact" do
        allow(ProviderSupport).to receive(:container_executable_provider_keys).and_return(%w[claude cursor aider opencode])
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret")
        opencode_provider = create_opencode_provider_entry(
          user: user,
          api_key: api_key,
          name: "Kimi K2.5",
          model: "moonshotai/kimi-k2-0905"
        )
        user.settings.update!(fallback_enabled: true, fallback_providers: [ opencode_provider.routing_key ])

        expect_opencode_fallback_execution(opencode_provider)
      end

      it "marks run as rate_limited when all providers are already rate limited in ProviderState" do
        reset_time = 2.hours.from_now

        # Pre-set all provider states as rate limited so provider_unavailable? skips them
        %w[claude cursor aider].each do |provider_name|
          user.provider_states.find_or_create_by!(provider_name: provider_name).tap do |state|
            state.update!(rate_limited_until: reset_time)
          end
        end

        # No container execution should occur since all providers are skipped
        expect(container_service).not_to receive(:execute)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.rate_limited_until).to be_present
      end

      it "preserves timeout status when timeout is followed by other failures" do
        call_count = 0
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          call_count += 1
          if call_count == 1
            raise Containers::Provision::TimeoutError, "took too long"
          else
            exec_failure
          end
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
          .and have_enqueued_job(ProcessRunQueueJob)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("wall_clock_timeout")
      end
    end

    context "when resolving user settings" do
      it "resolves user settings from project creator" do
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
      end

      it "raises MissingUser when no user is available" do
        orphan_account = create(:account)
        orphan_token = create(:github_token, :without_creator, account: orphan_account)
        project_without_creator = create(:project, :without_creator, account: orphan_account, github_token: orphan_token)
        issue_for_orphan = create(:issue, project: project_without_creator)
        orphan_run = create(:agent_run, :with_git_context, project: project_without_creator,
          issue: issue_for_orphan, container_id: "abc123")
        allow(AgentRun).to receive(:find).with(orphan_run.id).and_return(orphan_run)
        allow(orphan_token).to receive(:client).and_return(instance_double(GithubClient, issue_comments: []))

        expect {
          activity.execute(agent_run_id: orphan_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /No user available/)
      end
    end
  end

  describe "max_execution_seconds enforcement" do
    before do
      allow(container_service).to receive(:execute).and_return(exec_success)
      allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)
    end

    it "caps effective_timeout by remaining execution time" do
      project.update!(max_execution_seconds: 600)
      agent_run.update!(started_at: 5.minutes.ago, status: "running")

      expect(container_service).to receive(:execute).with(
        anything,
        hash_including(timeout: a_value <= 300)
      ).and_return(exec_success)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "pauses when execution time limit is exceeded" do
      project.update!(max_execution_seconds: 60)
      agent_run.update!(started_at: 2.minutes.ago, status: "running")

      allow(AgentRuns::Cancel).to receive(:call)

      result = activity.execute(agent_run_id: agent_run.id)

      agent_run.reload
      expect(result).to include(success: false, paused: true, agent_run_id: agent_run.id)
      expect(agent_run.status).to eq("paused")
      expect(agent_run.guardrail_violation_type).to eq("time_limit")
      expect(AgentRuns::Cancel).to have_received(:call).with(agent_run: agent_run, skip_status_update: true)
    end

    it "returns a paused result when the run was already paused by another guardrail" do
      project.update!(max_execution_seconds: 60)
      agent_run.update!(started_at: 2.minutes.ago, status: "running")

      violation_result = instance_double(Guardrails::ViolationHandler::Result, paused?: false)
      allow(Guardrails::ViolationHandler).to receive(:call) do
        agent_run.update!(status: "paused", paused_at: Time.current, guardrail_violation_type: "cost_limit")
        violation_result
      end

      result = activity.execute(agent_run_id: agent_run.id)

      agent_run.reload
      expect(result).to include(success: false, paused: true, agent_run_id: agent_run.id)
      expect(agent_run.status).to eq("paused")
      expect(agent_run.guardrail_violation_type).to eq("cost_limit")
    end
  end

  describe "loop guardrail handling" do
    before do
      allow(container_service).to receive(:execute).and_return(exec_success)
      allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)
    end

    it "returns a paused result when the run was already paused during loop handling" do
      allow(activity).to receive(:run_agent_with_provider).and_raise(described_class::InfiniteLoopError, "loop detected")

      violation_result = instance_double(Guardrails::ViolationHandler::Result, paused?: false)
      allow(Guardrails::ViolationHandler).to receive(:call) do
        agent_run.update!(status: "paused", paused_at: Time.current, guardrail_violation_type: "cost_limit")
        violation_result
      end

      result = activity.execute(agent_run_id: agent_run.id)

      agent_run.reload
      expect(result).to include(success: false, paused: true, agent_run_id: agent_run.id)
      expect(agent_run.status).to eq("paused")
      expect(agent_run.guardrail_violation_type).to eq("cost_limit")
    end
  end

  describe "paused run protection after provider exhaustion" do
    before do
      allow(container_service).to receive(:execute).and_return(exec_failure)
      allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)
    end

    it "preserves paused state when a guardrail paused the run during provider execution" do
      # Simulate a cost budget guardrail pausing the run during execution
      allow(container_service).to receive(:execute) do
        agent_run.update!(status: "paused", paused_at: Time.current, guardrail_violation_type: "cost_limit")
        exec_failure
      end

      result = activity.execute(agent_run_id: agent_run.id)

      agent_run.reload
      expect(result).to include(success: false, paused: true, agent_run_id: agent_run.id)
      expect(agent_run.status).to eq("paused")
      expect(agent_run.guardrail_violation_type).to eq("cost_limit")
    end
  end
end
