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
    # Ensure fallback is disabled by default so tests behave like single-runner runs
    user.settings.update!(fallback_enabled: false)

    # Stub github_client so effective_prompt → prompt_for_issue → BuildForIssue
    # does not make real HTTP calls (blocked by WebMock).
    github_client = instance_double(GithubClient, issue_comments: [])
    allow(project.github_token).to receive(:client).and_return(github_client)

    allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
    allow(Containers::Provision).to receive(:reconnect)
      .with(agent_run: agent_run, container_id: "abc123")
      .and_return(container_service)
    allow(container_service).to receive_messages(container_running?: true, container: nil, heartbeat_host_path: "/tmp/paid-heartbeat-test/.paid-heartbeat")
    allow(Containers::GitOperations).to receive(:new)
      .with(container_service: container_service, agent_run: agent_run)
      .and_return(git_ops)
    allow(git_ops).to receive_messages(
      write_co_author_trailer: nil,
      clone_and_restore_branch: nil,
      install_artifact_excludes: nil,
      install_git_hooks: nil,
      install_co_author_hook: nil
    )

    # By default, skip the runner preflight so tests that don't care
    # about preflight behaviour aren't affected by the smoke exec call.
    # Tests that verify preflight paths override this stub.
    allow(activity).to receive(:run_runner_preflight!)
  end

  def create_ab_test_assignment(slug:, agent_run:, variant_template:, status: "running")
    prompt = create(:prompt, :for_project, project: project, slug: slug)
    control_version = prompt.create_version!(template: "control {{base_prompt}}")
    variant_version = prompt.create_version!(template: variant_template)
    ab_test = create(:ab_test, prompt: prompt, control_version: control_version,
      status: status, started_at: Time.current)
    create(:ab_test_variant, ab_test: ab_test, prompt_version: control_version, is_control: true)
    variant = create(:ab_test_variant, ab_test: ab_test, prompt_version: variant_version)
    create(:ab_test_assignment, ab_test: ab_test, ab_test_variant: variant, agent_run: agent_run)

    variant_version
  end

  def expected_kilocode_model_config
    {
      "anthropic" => {
        "options" => {
          "apiKey" => "{env:ANTHROPIC_API_KEY}",
          "baseURL" => "https://api.anthropic.com"
        },
        "models" => {
          "claude-sonnet-4-20250514" => {
            "name" => "claude-sonnet-4-20250514",
            "id" => "claude-sonnet-4-20250514",
            "tool_call" => true
          }
        }
      }
    }
  end

  def create_running_ab_test(slug:)
    prompt = create(:prompt, :for_project, project: project, slug: slug)
    control_version = prompt.create_version!(template: "control {{base_prompt}} {{repo}}")
    variant_version = prompt.create_version!(template: "variant {{base_prompt}} {{repo}}")
    ab_test = create(:ab_test, prompt: prompt, control_version: control_version,
      status: "running", started_at: Time.current)
    create(:ab_test_variant, ab_test: ab_test, prompt_version: control_version, is_control: true)
    create(:ab_test_variant, ab_test: ab_test, prompt_version: variant_version)

    ab_test
  end

  def create_opencode_provider_for(user)
    api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
    create(:provider, :api_key,
      user: user,
      provider_key: "opencode",
      provider_api_key: api_key,
      config: {
        "opencode" => {
          "model" => "moonshotai/kimi-k2",
          "api_provider" => "openrouter"
        }
      })
  end

  def create_runner_backed_agent_run(project:, runner:)
    create(
      :agent_run,
      :with_git_context,
      project: project,
      issue: create(:issue, project: project),
      runner: runner,
      container_id: "abc123"
    )
  end

  def expect_all_runners_exhausted(activity:, agent_run:)
    allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

    expect {
      activity.execute(agent_run_id: agent_run.id)
    }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)
  end

  def trip_runner_circuit_with_preflight_timeouts(activity:, project:, runner:, attempts: 3)
    attempts.times do
      timed_out_run = create_runner_backed_agent_run(project: project, runner: runner)
      expect_all_runners_exhausted(activity: activity, agent_run: timed_out_run)
    end
  end

  def create_open_runner_state(user:, runner:, opened_at:, failure_count: 3)
    create(
      :runner_state,
      user: user,
      runner_name: runner.state_key,
      circuit_state: "open",
      failure_count: failure_count,
      circuit_opened_at: opened_at
    )
  end

  def run_direct_outbound_preflight(activity:, agent_run:, container_service:, provider:, user:)
    command_context = Activities::RunAgentActivity::CommandContext.new(
      runner_candidate: provider,
      runner: provider.runner_key,
      user: user
    )

    allow(activity).to receive(:run_runner_preflight!).and_call_original
    allow(activity).to receive_messages(
      preflight_provider_instance: nil,
      build_command: %w[echo ok],
      command_env_for: {},
      command_preparation_for: nil
    )

    activity.send(:run_runner_preflight!,
      agent_run: agent_run,
      container_service: container_service,
      command_context: command_context,
      runner: provider.runner_key,
      execution_env: {})
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

    it "does not report expected worker exceptions to stderr" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)

      expect {
        expect {
          activity.send(:with_periodic_heartbeat, "test", interval: 0.01) do
            raise ArgumentError, "boom"
          end
        }.to raise_error(ArgumentError, "boom")
      }.not_to output(/terminated with exception/).to_stderr
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

    it "propagates tenant context into the worker thread" do
      allow(Temporalio::Activity::Context).to receive(:current_or_nil).and_return(mock_context)

      TenantContext.with(user.account) do
        result = nil

        expect {
          result = activity.send(:with_periodic_heartbeat, "test", interval: 0.01) do
            agent_run.log!("system", "tenant context propagated")
            [
              Current.account,
              ActiveRecord::Base.connection.select_value("SELECT paid_current_account_id()")
            ]
          end
        }.to change { agent_run.agent_run_logs.count }.by(1)

        expect(result).to eq([ user.account, user.account.id ])
        expect(agent_run.agent_run_logs.order(:id).last.content).to eq("tenant context propagated")
      end
    end
  end

  describe ".container_executable?" do
    it "recognizes codex as container executable" do
      expect(described_class.container_executable?("codex")).to be true
    end

    it "recognizes gemini as container executable" do
      expect(described_class.container_executable?("gemini")).to be true
    end

    it "recognizes kilocode as container executable" do
      expect(described_class.container_executable?("kilocode")).to be true
    end

    it "recognizes opencode as container executable" do
      expect(described_class.container_executable?("opencode")).to be true
    end

    it "treats copilot as container executable via autopilot mode" do
      expect(described_class.container_executable?("copilot")).to be true
    end

    it "recognizes claude_code via agent type mapping" do
      expect(described_class.container_executable?("claude_code")).to be true
    end

    it "rejects unknown runners" do
      expect(described_class.container_executable?("unknown")).to be false
    end
  end

  describe "zero-iteration timeout notifications" do
    before do
      allow(Notifications::Rules::ZeroIterationTimeout).to receive(:call)
      allow(activity).to receive(:track_phase).and_yield
      allow(activity).to receive_messages(
        resolve_user_settings: user.settings,
        build_runner_order: [ "claude_code" ],
        load_runner_state_cache: {},
        runner_command_key: "claude",
        runner_attempt_label: "claude",
        state_key_for: "claude",
        runner_unavailable?: false,
        cancelled_by_cleanup?: false
      )
      allow(activity).to receive(:heartbeat)
      allow(activity).to receive(:record_runner_failure)
      allow(activity).to receive(:run_agent_with_runner)
        .and_raise(Activities::RunAgentActivity::RunnerTimeoutError, "wall clock timeout")
      allow(ProcessRunQueueJob).to receive(:perform_later)
    end

    it "checks the zero-iteration timeout rule after timing out a run" do
      agent_run.project.update!(max_execution_seconds: 10_000)
      agent_run.update!(status: "running", started_at: 1.minute.ago, iterations: 0, tokens_input: 0)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError, "All runners exhausted")

      expect(Notifications::Rules::ZeroIterationTimeout).to have_received(:call).with(scope: agent_run)
    end
  end

  describe "timeout fallback to next runner" do
    before do
      allow(activity).to receive(:track_phase).and_yield
      allow(activity).to receive_messages(
        resolve_user_settings: user.settings,
        build_runner_order: %w[claude_code codex],
        load_runner_state_cache: {},
        runner_command_key: "claude",
        runner_attempt_label: "claude",
        state_key_for: "claude",
        runner_unavailable?: false,
        cancelled_by_cleanup?: false
      )
      allow(activity).to receive(:heartbeat)
      allow(activity).to receive(:record_runner_failure)
      allow(ProcessRunQueueJob).to receive(:perform_later)
    end

    it "falls through to next runner after timeout instead of breaking" do
      agent_run.project.update!(max_execution_seconds: 10_000)
      agent_run.update!(status: "running", started_at: 1.minute.ago, iterations: 0, tokens_input: 0)

      call_count = 0
      allow(activity).to receive(:run_agent_with_runner) do
        call_count += 1
        raise Activities::RunAgentActivity::RunnerTimeoutError, "idle timeout"
      end

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError, "All runners exhausted")

      # Both runners should have been attempted
      expect(call_count).to eq(2)
    end
  end

  describe "harness-generated commands" do
    it "generates codex command with sandbox bypass through agent-harness" do
      plan = Runners::HarnessExecutionPlan.for_runner_key(
        runner_key: "codex", prompt: "test", options: { dangerous_mode: true }
      )
      expect(plan.command).to include("codex", "exec")
      expect(plan.command).to include("--dangerously-bypass-approvals-and-sandbox")
    end

    it "generates claude command with dangerous-mode flags through agent-harness" do
      plan = Runners::HarnessExecutionPlan.for_runner_key(
        runner_key: "claude", prompt: "test", options: { dangerous_mode: true }
      )
      expect(plan.command).to include("claude", "--print", "--dangerously-skip-permissions")
    end

    it "generates copilot env that bypasses approval prompts in dangerous mode" do
      plan = Runners::HarnessExecutionPlan.for_runner_key(
        runner_key: "copilot", prompt: "test", options: { dangerous_mode: true }
      )
      expect(plan.command).to include("copilot", "--autopilot")
      expect(plan.env).to include("COPILOT_ALLOW_ALL" => "true")
    end
  end

  describe ".runner_order" do
    it "returns only the primary runner when fallback is disabled" do
      result = described_class.runner_order(
        agent_type: "claude_code",
        fallback_enabled: false,
        fallback_runners: %w[cursor aider]
      )

      expect(result).to eq([ "claude_code" ])
    end

    it "deduplicates canonical runners in fallback order" do
      result = described_class.runner_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_runners: %w[claude cursor aider]
      )

      expect(result).to eq(%w[claude_code cursor aider])
    end

    it "includes codex in fallback order when listed" do
      result = described_class.runner_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_runners: %w[codex cursor]
      )

      expect(result).to eq(%w[claude_code codex cursor])
    end

    it "includes gemini in fallback order when listed" do
      result = described_class.runner_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_runners: %w[gemini codex]
      )

      expect(result).to eq(%w[claude_code gemini codex])
    end

    it "includes kilocode in fallback order when listed" do
      result = described_class.runner_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_runners: %w[kilocode codex]
      )

      expect(result).to eq(%w[claude_code kilocode codex])
    end

    it "includes opencode in fallback order when listed" do
      result = described_class.runner_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_runners: %w[opencode codex]
      )

      expect(result).to eq(%w[claude_code opencode codex])
    end

    it "includes copilot in fallback order as a container-executable runner" do
      result = described_class.runner_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_runners: %w[copilot codex]
      )

      expect(result).to eq(%w[claude_code copilot codex])
    end
  end

  describe ".runner_attempt_count" do
    it "matches provider_order size for deduplicated fallback runners" do
      count = described_class.runner_attempt_count(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_runners: %w[claude cursor aider]
      )

      expect(count).to eq(3)
    end
  end

  describe "#build_command" do
    it "builds a sh -c wrapper for Codex subscription auth" do
      context = described_class::CommandContext.new(
        runner_candidate: "codex",
        runner: "codex",
        user: nil
      )
      command = activity.send(:build_command, context, "say 'hi'")
      script = command[2]

      expect(command[0..1]).to eq(%w[sh -c])
      expect(script).to include('if [ "$PAID_CODEX_SUBSCRIPTION_AUTH" = "1" ]')
      expect(script).to include("-u OPENAI_API_KEY")
      expect(script).to include("codex")
      expect(command[3]).to eq("--")
      expect(command[4]).to eq("say 'hi'")
    end

    it "builds a sh -c wrapper for Gemini subscription auth" do
      context = described_class::CommandContext.new(
        runner_candidate: "gemini",
        runner: "gemini",
        user: nil
      )
      command = activity.send(:build_command, context, "say 'hi'")
      script = command[2]

      expect(command[0..1]).to eq(%w[sh -c])
      expect(script).to include('if [ "$PAID_GEMINI_SUBSCRIPTION_AUTH" = "1" ]')
      expect(script).to include("-u GEMINI_API_KEY")
      expect(script).to include("-u GOOGLE_GEMINI_BASE_URL")
      expect(script).to include("gemini")
      expect(command[3]).to eq("--")
      expect(command[4]).to eq("say 'hi'")
    end

    it "preserves multi-line prompts as a positional parameter" do
      multiline_prompt = "First line\nSecond line\n  indented third"
      context = described_class::CommandContext.new(
        runner_candidate: "codex",
        runner: "codex",
        user: nil
      )
      command = activity.send(:build_command, context, multiline_prompt)

      expect(command[4]).to eq(multiline_prompt)
      expect(command[2]).not_to include("\n")
    end

    it "wraps Claude in a subscription-auth check now that agent-harness provides subscription_unset_vars" do
      context = described_class::CommandContext.new(
        runner_candidate: "claude",
        runner: "claude",
        user: nil
      )
      command = activity.send(:build_command, context, "ping")

      expect(command.first).to eq("sh")
      script = command[2]
      expect(script).to include('PAID_CLAUDE_SUBSCRIPTION_AUTH')
      expect(script).to include("claude")
      expect(command.last).to eq("ping")
    end

    it "passes the tier-resolved model to agent-harness for Claude commands" do
      llm_model = create(:llm_model, model_id: "claude-sonnet-4-6", provider: "anthropic", tier: "mid")
      create(:model_selection, agent_run: agent_run, llm_model: llm_model)
      context = described_class::CommandContext.new(
        runner_candidate: "claude",
        runner: "claude",
        user: nil
      )

      expect(Runners::HarnessExecutionPlan).to receive(:for_runner_key).with(
        runner_key: "claude",
        prompt: "ping",
        options: hash_including(dangerous_mode: true),
        provider_runtime: have_attributes(model: "claude-sonnet-4-6")
      ).and_call_original

      command = activity.send(:build_command, context, "ping", agent_run: agent_run)

      expect(command.first).to eq("sh")
    end

    it "injects --model into the subscription-auth shell script when a tier model is resolved" do
      llm_model = create(:llm_model, model_id: "claude-opus-4-6", provider: "anthropic", tier: "high")
      create(:model_selection, agent_run: agent_run, llm_model: llm_model)
      context = described_class::CommandContext.new(
        runner_candidate: "claude",
        runner: "claude",
        user: nil
      )

      command = activity.send(:build_command, context, "ping", agent_run: agent_run)
      script = command[2]

      expect(command.first).to eq("sh")
      expect(script).to include("--model claude-opus-4-6")
    end

    it "does not duplicate --model when the harness already includes it" do
      llm_model = create(:llm_model, model_id: "claude-opus-4-6", provider: "anthropic", tier: "high")
      create(:model_selection, agent_run: agent_run, llm_model: llm_model)
      context = described_class::CommandContext.new(
        runner_candidate: "claude",
        runner: "claude",
        user: nil
      )

      # Stub the harness plan to already include --model in the command
      fake_plan = Runners::HarnessExecutionPlan::Result.new(
        command: %w[claude --model claude-opus-4-6 --dangerously-skip-permissions ping])
      allow(activity).to receive(:harness_execution_plan_for).and_return(fake_plan)

      prefix = activity.send(:inject_runtime_model_flag,
        fake_plan.command[0..-2], context, agent_run: agent_run)

      # --model should not be added again since the command already has it
      expect(prefix.count { |arg| arg == "--model" }).to eq(1)
    end

    it "does not inject --model for non-claude subscription runners" do
      llm_model = create(:llm_model, model_id: "copilot-model-1", provider: "github", tier: "mid")
      create(:model_selection, agent_run: agent_run, llm_model: llm_model)
      context = described_class::CommandContext.new(
        runner_candidate: "copilot",
        runner: "copilot",
        user: nil
      )

      prefix = activity.send(:inject_runtime_model_flag,
        %w[copilot --print], context, agent_run: agent_run)

      expect(prefix).not_to include("--model")
    end

    it "uses the runner's tier resolution even when the selected model is from another provider" do
      create(:llm_model, model_id: "claude-sonnet-4-6", provider: "anthropic", tier: "mid", capability_score: 9.0)
      llm_model = create(:llm_model, model_id: "gpt-5.4", provider: "openai", tier: "mid")
      create(:model_selection, agent_run: agent_run, llm_model: llm_model)
      context = described_class::CommandContext.new(
        runner_candidate: "claude",
        runner: "claude",
        user: nil
      )

      expect(Runners::HarnessExecutionPlan).to receive(:for_runner_key).with(
        runner_key: "claude",
        prompt: "ping",
        options: hash_including(dangerous_mode: true),
        provider_runtime: have_attributes(model: "claude-sonnet-4-6")
      ).and_call_original

      command = activity.send(:build_command, context, "ping", agent_run: agent_run)

      expect(command.first).to eq("sh")
    end

    it "builds an API-key wrapper for anthropic-backed fallback entries" do
      api_key = create(:runner_api_key, user: user, api_service_type: "anthropic", api_key: "sk-anthropic-secret")
      runner = create(:runner, :api_key, user: user, runner_key: "claude", provider_api_key: api_key)
      context = described_class::CommandContext.new(
        runner_candidate: runner.routing_key,
        runner: "claude",
        user: user
      )

      command = activity.send(:build_command, context, "ping")
      env = activity.send(:command_env_for, context, "ping")

      expect(command[0..1]).to eq(%w[sh -c])
      expect(command[2]).to include('ANTHROPIC_BASE_URL="$PAID_PROXY_URL/api/proxy/anthropic"')
      expect(command[2]).to include('ANTHROPIC_HEADER_X_AGENT_RUN_ID="$AGENT_RUN_ID"')
      expect(command[2]).to include('ANTHROPIC_HEADER_X_PROXY_TOKEN="$PROXY_TOKEN"')
      expect(command[2]).to include('ANTHROPIC_HEADER_X_PAID_PROVIDER_ID="$PAID_PROVIDER_ID"')
      expect(command[2]).to include('ANTHROPIC_API_KEY="paid-run:$AGENT_RUN_ID:$PROXY_TOKEN"')
      expect(command[2]).not_to include("sk-anthropic-secret")
      expect(command[3]).to eq("--")
      expect(command[4]).to eq("ping")
      expect(env).to eq("PAID_PROVIDER_ID" => runner.id.to_s)
    end

    it "builds an API-key wrapper for OpenAI-backed fallback entries without injecting the runner key" do
      api_key = create(:runner_api_key, user: user, api_service_type: "openai", api_key: "sk-openai-secret")
      runner = create(:runner, :api_key, user: user, runner_key: "codex", provider_api_key: api_key)
      context = described_class::CommandContext.new(
        runner_candidate: runner.routing_key,
        runner: "codex",
        user: user
      )

      command = activity.send(:build_command, context, "ping")
      env = activity.send(:command_env_for, context, "ping")

      expect(command[2]).to include('OPENAI_HEADER_X_PAID_PROVIDER_ID="$PAID_PROVIDER_ID"')
      expect(command[2]).to include('OPENAI_API_KEY="paid-run:$AGENT_RUN_ID:$PROXY_TOKEN"')
      expect(command[2]).not_to include("sk-openai-secret")
      expect(env).to eq("PAID_PROVIDER_ID" => runner.id.to_s)
    end

    it "builds an API-key wrapper for Google-backed fallback entries without injecting the runner key" do
      api_key = create(:runner_api_key, user: user, api_service_type: "google", api_key: "google-secret")
      runner = create(:runner, :api_key, user: user, runner_key: "gemini", provider_api_key: api_key)
      context = described_class::CommandContext.new(
        runner_candidate: runner.routing_key,
        runner: "gemini",
        user: user
      )

      command = activity.send(:build_command, context, "ping")
      env = activity.send(:command_env_for, context, "ping")

      expect(command[2]).to include('GOOGLE_HEADER_X_PAID_PROVIDER_ID="$PAID_PROVIDER_ID"')
      expect(command[2]).to include("X-Paid-Provider-Id: $PAID_PROVIDER_ID")
      expect(command[2]).to include('GEMINI_API_KEY="paid-run:$AGENT_RUN_ID:$PROXY_TOKEN"')
      expect(command[2]).to include('GOOGLE_API_KEY="paid-run:$AGENT_RUN_ID:$PROXY_TOKEN"')
      expect(command[2]).not_to include("google-secret")
      expect(env).to eq("PAID_PROVIDER_ID" => runner.id.to_s)
    end

    it "uses canonical runner state keys for subscription entries" do
      subscription_runner = user.runners.find_by!(runner_key: "claude")
      state_key = activity.send(:state_key_for, subscription_runner.routing_key, "claude", user)

      expect(state_key).to eq("claude")
    end

    context "with a direct-outbound OpenCode runner" do
      it "builds the command through agent-harness runtime preparation" do
        opencode_context = build_opencode_context(user)
        command = activity.send(:build_command, opencode_context, "ping")
        env = activity.send(:command_env_for, opencode_context, "ping")
        preparation = activity.send(:command_preparation_for, opencode_context, "ping")

        expect(command).to eq([ "env", "-u", "OPENAI_HEADER_X_AGENT_RUN_ID", "-u", "OPENAI_HEADER_X_PROXY_TOKEN", "opencode", "run", "ping" ])
        expect(env).to include("OPENROUTER_API_KEY" => "sk-openrouter-secret", "OPENAI_BASE_URL" => "https://openrouter.ai/api/v1")
        expect(preparation.file_writes.first.path).to eq("~/.config/opencode/opencode.json")
        expect(preparation.file_writes.first.content).to include("\"model\": \"openrouter/moonshotai/kimi-k2-0905\"")
      end

      it "preserves multi-line prompts when wrapping the harness runtime command" do
        opencode_context = build_opencode_context(user)
        prompt = "line 1\nline 2"

        command = activity.send(:build_command, opencode_context, prompt)

        expect(command).to eq([ "env", "-u", "OPENAI_HEADER_X_AGENT_RUN_ID", "-u", "OPENAI_HEADER_X_PROXY_TOKEN", "opencode", "run", prompt ])
      end
    end

    it "returns nil preparation when no persisted runner exists and the bare runner key is unknown" do
      context = described_class::CommandContext.new(
        runner_candidate: nil,
        runner: "not_a_real_runner",
        user: user
      )

      expect(activity.send(:command_preparation_for, context, "ping")).to be_nil
    end

    context "with a direct-outbound kilocode runner" do
      it "includes PAID_KILOCODE_CONFIG_B64 in command env alongside PAID_PROVIDER_ID" do
        context = build_kilocode_context(user)

        command = activity.send(:build_command, context, "ping")
        env = activity.send(:command_env_for, context, "ping")

        expect(command[0]).to eq("sh")
        expect(command[1]).to eq("-lc")
        expect(command[2]).to include("PAID_KILOCODE_CONFIG_B64")
        expect(command[2]).to include("kilo run --format json")
        expect(command.last).to eq("ping")

        expect(env).to have_key("PAID_KILOCODE_CONFIG_B64")
        expect(env).to include("ANTHROPIC_API_KEY" => "sk-anthropic-secret")
        expect(env).to have_key("PAID_PROVIDER_ID")
        config_json = JSON.parse(Base64.strict_decode64(env["PAID_KILOCODE_CONFIG_B64"]))
        expect(config_json["model"]).to eq("anthropic/claude-sonnet-4-20250514")
        expect(config_json["provider"]).to eq(expected_kilocode_model_config)
      end

      it "does not include PAID_KILOCODE_CONFIG_B64 for subscription kilocode runners" do
        subscription_runner = create(:runner, user: user, runner_key: "kilocode", auth_type: "subscription")
        context = described_class::CommandContext.new(
          runner_candidate: subscription_runner.routing_key,
          runner: "kilocode",
          user: user
        )

        env = activity.send(:command_env_for, context, "ping")

        expect(env).not_to have_key("PAID_KILOCODE_CONFIG_B64")
      end
    end

    context "with a persisted copilot runner" do
      it "propagates dangerous-mode approval bypass through the harness runtime path" do
        runner = create(:runner, user: user, runner_key: "copilot", auth_type: "subscription")
        context = described_class::CommandContext.new(
          runner_candidate: runner.routing_key,
          runner: "copilot",
          user: user
        )

        command = activity.send(:build_command, context, "ping")
        env = activity.send(:command_env_for, context, "ping")

        expect(command).to include("copilot", "--autopilot")
        expect(env).to include("COPILOT_ALLOW_ALL" => "true")
      end

      it "does not unset COPILOT_GITHUB_TOKEN in subscription auth wrapper" do
        context = described_class::CommandContext.new(
          runner_candidate: "copilot",
          runner: "copilot",
          user: nil
        )
        command = activity.send(:build_command, context, "ping")

        script = command[2]
        expect(script).to include("PAID_COPILOT_SUBSCRIPTION_AUTH")
        expect(script).not_to include("-u COPILOT_GITHUB_TOKEN")
        expect(script).to include("-u GH_TOKEN")
      end
    end

    it "keeps the configured runtime when a direct-outbound runner disagrees with the selected model" do
      opencode_context = build_opencode_context(user)
      llm_model = create(:llm_model, model_id: "different-model", provider: "openrouter")
      create(:model_selection, agent_run: agent_run, llm_model: llm_model)

      command = activity.send(:build_command, opencode_context, "ping", agent_run: agent_run)
      preparation = activity.send(:command_preparation_for, opencode_context, "ping")

      expect(command).to eq([ "env", "-u", "OPENAI_HEADER_X_AGENT_RUN_ID", "-u", "OPENAI_HEADER_X_PROXY_TOKEN", "opencode", "run", "ping" ])
      expect(preparation.file_writes.first.content).to include("\"model\": \"openrouter/moonshotai/kimi-k2-0905\"")
    end
  end

  describe "#selected_runner_runtime" do
    it "ignores Paid model selection for Codex subscription-auth runs" do
      codex_provider = create(:provider, user: user, provider_key: "codex", auth_type: "subscription")
      runtime_issue = create(:issue, project: project)
      run = create(:agent_run, :with_git_context,
        project: project,
        issue: runtime_issue,
        agent_type: "codex",
        provider: codex_provider,
        container_id: "abc123")
      create(:model_selection, agent_run: run, llm_model: create(:llm_model, :openai, model_id: "gpt-4o"))

      runtime = activity.send(:selected_runner_runtime, codex_provider, nil, run)

      expect(runtime).to be_nil
    end

    it "keeps the configured runtime for direct-outbound runners with a different selected model" do
      opencode_context = build_opencode_context(user)
      create(:model_selection, agent_run: agent_run, llm_model: create(:llm_model, model_id: "different-model", provider: "openrouter"))

      runtime = activity.send(:selected_runner_runtime, opencode_context.runner_candidate, user, agent_run)

      # OpenRouter ids are "<vendor>/<model>" slugs that opencode addresses
      # directly, so they pass through unchanged (matching the execute path and
      # openrouter_free runtime) rather than gaining a redundant prefix.
      expect(runtime).to have_attributes(model: "moonshotai/kimi-k2-0905", api_provider: nil)
    end

    it "provider-qualifies the resolved tier model for opencode MiniMax direct-outbound runs" do
      # Regression: the bare tier_model_ids value ("MiniMax-M3") overwrote the
      # qualified configured model, so opencode received an unqualified id and
      # raised ProviderModelNotFoundError (providerID="MiniMax-M3", modelID="").
      opencode_context = build_opencode_context(
        user, api_provider: "minimax", model: "MiniMax-M3", service_type: "minimax", api_key: "sk-minimax-secret"
      )
      create(:model_selection, agent_run: agent_run, llm_model: create(:llm_model, model_id: "minimax-selected", provider: "minimax"))

      runtime = activity.send(:selected_runner_runtime, opencode_context.runner_candidate, user, agent_run)

      expect(runtime.model).to eq("minimax/MiniMax-M3")
    end

    it "does not double-qualify an already-prefixed tier model" do
      opencode_context = build_opencode_context(
        user, api_provider: "minimax", model: "minimax/MiniMax-M3", service_type: "minimax", api_key: "sk-minimax-secret"
      )
      create(:model_selection, agent_run: agent_run, llm_model: create(:llm_model, model_id: "minimax-selected", provider: "minimax"))

      runtime = activity.send(:selected_runner_runtime, opencode_context.runner_candidate, user, agent_run)

      expect(runtime.model).to eq("minimax/MiniMax-M3")
    end

    it "builds OpenRouter provider routing for openrouter_free runs from project classification" do
      api_key = create(:runner_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret")
      free_model = create(:llm_model, model_id: "deepseek/deepseek-v4-flash:free", provider: "deepseek", tier: "mid", pricing_tier: "free")
      restricted_run = build_openrouter_free_run(project: project, model: free_model, data_classification: "restricted")
      runner = create_openrouter_free_runner(user: user, api_key: api_key, model: free_model.model_id)

      runtime = activity.send(:selected_runner_runtime, runner, user, restricted_run)

      expect(runtime.model).to eq("deepseek/deepseek-v4-flash:free")
      expect(runtime.env).to include(
        "OPENROUTER_API_KEY" => "sk-openrouter-secret",
        "OPENAI_BASE_URL" => "https://openrouter.ai/api/v1"
      )
      expect(runtime.metadata[:config]["provider"]).to eq(
        { "openrouter" => { data_collection: "deny", zdr: true } }
      )
    end

    it "raises instead of falling back to an unpinned runtime when no free model resolves for openrouter_free" do
      api_key = create(:runner_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret")
      free_model = create(:llm_model, model_id: "deepseek/deepseek-v4-flash:free", provider: "deepseek", tier: "mid", pricing_tier: "free")
      run = build_openrouter_free_run(project: project, model: free_model, data_classification: "internal")
      runner = create_openrouter_free_runner(user: user, api_key: api_key, model: free_model.model_id)

      allow(Runners::ResolveTierModel).to receive(:call).and_return(
        Runners::ResolveTierModel::Result.new(error: "no model configured")
      )

      expect do
        activity.send(:selected_runner_runtime, runner, user, run)
      end.to raise_error(Activities::RunAgentActivity::RunnerExecutionError, /no resolvable free model/)
    end

    it "ignores Paid model selection when Codex subscription auth is referenced by bare runner key" do
      create(:provider, user: user, provider_key: "codex", auth_type: "subscription")
      create(:model_selection, agent_run: agent_run, llm_model: create(:llm_model, :openai, model_id: "gpt-4o", tier: "mid"))

      # Bare key — what fallback chains pass into the runner loop. Previously
      # the subscription guard only fired for routing keys (`"runner:NN"`),
      # so a fallback to "codex" leaked `--model gpt-4o` into the CLI even
      # though the subscription /v1/responses endpoint rejects it.
      runtime = activity.send(:selected_runner_runtime, "codex", user, agent_run)

      expect(runtime).to be_nil
    end

    it "memoizes the bare-key Codex subscription lookup per user across calls" do
      create(:provider, user: user, provider_key: "codex", auth_type: "subscription")

      expect(Runner).to receive(:for_identifier).once.with(user, "codex").and_call_original

      2.times do
        expect(activity.send(:selected_runner_runtime, "codex", user, agent_run)).to be_nil
      end
    end
  end

  describe "#runner_entry_for" do
    it "memoizes routing-key lookups per user and identifier" do
      runner = create(:runner, user: user, runner_key: "opencode")

      expect(Runner).to receive(:for_identifier).once.with(user, runner.routing_key).and_call_original

      2.times do
        expect(activity.send(:runner_entry_for, runner.routing_key, user)).to eq(runner)
      end
    end
  end

  describe "#augment_prompt_for_enhance_issue_goal" do
    before do
      allow(Prompt).to receive(:resolve).and_return(nil)
    end

    it "includes knowledge context when artifacts are available" do
      base_prompt = "Enhance this issue with implementation context."
      allow(Knowledge::ContextBundle::Build).to receive(:call)
        .with(issue: issue, project: project, agent_run: agent_run, agent_run_id: agent_run.id)
        .and_return(content: "## Codebase Context\n\n- Hunt#last_active uses prey.updated_at")

      prompt = activity.send(:augment_prompt_for_enhance_issue_goal, agent_run, base_prompt)

      expect(prompt).to include(base_prompt)
      expect(prompt).to include("## Codebase Context")
      expect(prompt).to include("Hunt#last_active uses prey.updated_at")
      expect(prompt).to include("Read issue ##{issue.github_number} in #{project.full_name}")
    end

    it "renders without knowledge context when no artifacts are available" do
      base_prompt = "Enhance this issue with implementation context."
      allow(Knowledge::ContextBundle::Build).to receive(:call)
        .with(issue: issue, project: project, agent_run: agent_run, agent_run_id: agent_run.id)
        .and_return(content: "")

      prompt = activity.send(:augment_prompt_for_enhance_issue_goal, agent_run, base_prompt)

      expect(prompt).to include(base_prompt)
      expect(prompt).not_to include("## Codebase Context")
      expect(prompt).to include("Only add a comment to issue ##{issue.github_number}")
    end
  end

  describe "goal prompt version persistence" do
    it "persists prompt_version_id for review-goal runs" do
      prompt = create(:prompt, :for_project, project: project, slug: described_class::REVIEW_GOAL_PROMPT_SLUG)
      version = prompt.create_version!(template: "review {{base_prompt}} {{repo}} {{pr_number}}")
      run = create(:agent_run, :review_goal, project: project)

      activity.send(:augment_prompt_for_review_goal, run, "Review the branch")

      expect(run.reload.prompt_version).to eq(version)
    end

    it "persists prompt_version_id for issue-goal runs without an existing version" do
      prompt = create(:prompt, :for_project, project: project, slug: described_class::ISSUE_GOAL_PROMPT_SLUG)
      version = prompt.create_version!(template: "issue {{base_prompt}} {{repo}}")
      run = create(:agent_run, :create_issue_goal, project: project)

      rendered = activity.send(:augment_prompt_for_issue_goal, run, "Create the issue")

      expect(run.reload.prompt_version).to eq(version)
      expect(rendered).to include("issue Create the issue #{project.full_name}")
      expect(rendered).to include("Do NOT reply by asking the user to provide the issue type, title, description,")
    end

    it "persists prompt_version_id for enhance-issue-goal runs" do
      prompt = create(:prompt, :for_project, project: project, slug: described_class::ENHANCE_ISSUE_GOAL_PROMPT_SLUG)
      version = prompt.create_version!(template: "enhance {{base_prompt}} {{repo}} {{issue_number}}")
      run = create(:agent_run, :enhance_issue_goal, project: project, issue: issue)
      allow(Knowledge::ContextBundle::Build).to receive(:call)
        .with(issue: issue, project: project, agent_run: run, agent_run_id: run.id)
        .and_return(content: "")

      activity.send(:augment_prompt_for_enhance_issue_goal, run, "Enhance this issue")

      expect(run.reload.prompt_version).to eq(version)
    end

    it "does not overwrite an existing prompt_version_id" do
      existing_version = create(:prompt_version)
      prompt = create(:prompt, :for_project, project: project, slug: described_class::ISSUE_GOAL_PROMPT_SLUG)
      prompt.create_version!(template: "goal {{base_prompt}} {{repo}}")
      run = create(:agent_run, :create_issue_goal, project: project, prompt_version: existing_version)

      activity.send(:augment_prompt_for_issue_goal, run, "Create the issue")

      expect(run.reload.prompt_version).to eq(existing_version)
    end

    it "falls back to inline template when no prompt version exists" do
      allow(Prompt).to receive(:resolve).and_return(nil)
      run = create(:agent_run, :review_goal, project: project)

      prompt = activity.send(:augment_prompt_for_review_goal, run, "Review the branch")

      expect(run.reload.prompt_version_id).to be_nil
      expect(prompt).to include("Review the branch")
    end
  end

  describe "#augment_prompt_for_issue_goal knowledge injection" do
    before do
      allow(Prompt).to receive(:resolve).and_return(nil)
    end

    it "injects knowledge context for issue-goal runs with custom_prompt" do
      run = create(:agent_run, :create_issue_goal, project: project, issue: issue, custom_prompt: "Custom coding prompt")
      allow(Knowledge::ContextBundle::Build).to receive(:call)
        .with(issue: issue, project: project, agent_run: run, agent_run_id: run.id)
        .and_return(content: "## Codebase Context\n\n- important context")

      prompt = activity.send(:augment_prompt_for_issue_goal, run, "Custom coding prompt")

      expect(prompt).to include("## Codebase Context")
      expect(prompt).to include("important context")
    end

    it "skips knowledge injection when no custom_prompt is set (BuildForIssue already injected)" do
      run = create(:agent_run, :create_issue_goal, project: project, issue: issue, custom_prompt: nil)

      expect(Knowledge::ContextBundle::Build).not_to receive(:call)

      activity.send(:augment_prompt_for_issue_goal, run, "BuildForIssue-generated prompt with knowledge")
    end

    it "tells the agent to synthesize the issue instead of asking for drafting fields" do
      run = create(:agent_run, :create_issue_goal, project: project, issue: issue)

      prompt = activity.send(:augment_prompt_for_issue_goal, run, "Create the issue")

      expect(prompt).to match(/Synthesize the issue title, body,\s+and any appropriate labels/)
      expect(prompt).to include("Do NOT reply by asking the user to provide the issue type, title, description,")
      expect(prompt).to match(/When no labels are\s+clearly requested, omit them\./)
    end
  end

  describe "#decomposition_instructions_for" do
    before do
      allow(Prompt).to receive(:resolve).and_return(nil)
    end

    it "returns decomposition instructions when scope analysis triggers decomposition" do
      large_body = <<~TEXT
        ## Feature: User Notification System

        Redesign the notification system to support multiple channels.

        ### Requirements
        1. Create database migrations for notification preferences
        2. Build service layer for dispatching notifications
        3. Add API endpoints for managing preferences
        4. Build dashboard UI for notification history
        5. Add background jobs for async delivery
        6. Implement caching for notification templates
      TEXT
      decompose_issue = create(:issue, project: project, body: large_body)
      run = create(:agent_run, :create_issue_goal, project: project, issue: decompose_issue)

      result = activity.send(:decomposition_instructions_for, run)

      expect(result).to include("Feature Decomposition")
      expect(result).to include("multi-issue-plan-start")
      expect(result).to include("do NOT create any GitHub issue directly")
      expect(result).to include("do not add `Depends on #N`")
    end

    it "returns empty string when scope analysis does not trigger decomposition" do
      small_issue = create(:issue, project: project, body: "Fix the login button color")
      run = create(:agent_run, :create_issue_goal, project: project, issue: small_issue)

      result = activity.send(:decomposition_instructions_for, run)

      expect(result).to eq("")
    end

    it "returns empty string when issue has no-decompose label" do
      large_body = <<~TEXT
        Redesign the notification system with models, services, controllers,
        views, background jobs, caching, and authentication. Step 1: create
        migrations. Step 2: build services. Step 3: add API endpoints.
      TEXT
      no_decompose_issue = create(:issue, project: project, body: large_body, labels: [ "no-decompose" ])
      run = create(:agent_run, :create_issue_goal, project: project, issue: no_decompose_issue)

      result = activity.send(:decomposition_instructions_for, run)

      expect(result).to eq("")
    end

    it "returns empty string when issue has no body" do
      no_body_issue = create(:issue, project: project, body: nil)
      run = create(:agent_run, :create_issue_goal, project: project, issue: no_body_issue)

      result = activity.send(:decomposition_instructions_for, run)

      expect(result).to eq("")
    end

    it "returns empty string when agent run has no issue" do
      run = create(:agent_run, :create_issue_goal, project: project, issue: nil)

      result = activity.send(:decomposition_instructions_for, run)

      expect(result).to eq("")
    end
  end

  describe "A/B test goal prompt assignment" do
    let(:large_decomposition_body) do
      <<~TEXT
        ## Feature: User Notification System

        Redesign the notification system to support multiple channels.

        ### Requirements
        1. Create database migrations for notification preferences
        2. Build service layer for dispatching notifications
        3. Add API endpoints for managing preferences
        4. Build dashboard UI for notification history
        5. Add background jobs for async delivery
        6. Implement caching for notification templates
      TEXT
    end

    it "assigns a running test before rendering the issue-goal prompt" do
      run = create(:agent_run, :create_issue_goal, project: project)
      ab_test = create_running_ab_test(slug: described_class::ISSUE_GOAL_PROMPT_SLUG)

      prompt = activity.send(:augment_prompt_for_issue_goal, run, "Create a roadmap issue")

      assignment = AbTestAssignment.find_by!(ab_test: ab_test, agent_run: run)
      assigned_version = assignment.ab_test_variant.prompt_version

      expect(prompt).to include(assigned_version.render(base_prompt: "Create a roadmap issue", repo: project.full_name))
      expect(prompt).to include("Do NOT reply by asking the user to provide the issue type, title, description,")
      expect(run.reload.prompt_version).to eq(assigned_version)
    end

    it "uses an assigned issue-goal variant prompt version" do
      run = create(:agent_run, :create_issue_goal, project: project)
      variant_version = create_ab_test_assignment(
        slug: described_class::ISSUE_GOAL_PROMPT_SLUG,
        agent_run: run,
        variant_template: "variant {{base_prompt}} {{repo}}"
      )

      prompt = activity.send(:augment_prompt_for_issue_goal, run, "Create a roadmap issue")

      expect(prompt).to include("variant Create a roadmap issue #{project.full_name}")
      expect(prompt).to include("Do NOT reply by asking the user to provide the issue type, title, description,")
      expect(run.reload.prompt_version).to eq(variant_version)
    end

    it "appends drafting and decomposition instructions for assigned issue-goal variants that predate them" do
      decompose_issue = create(:issue, project: project, body: large_decomposition_body)
      run = create(:agent_run, :create_issue_goal, project: project, issue: decompose_issue)
      create_ab_test_assignment(
        slug: described_class::ISSUE_GOAL_PROMPT_SLUG,
        agent_run: run,
        variant_template: "variant {{base_prompt}} {{repo}}"
      )

      prompt = activity.send(:augment_prompt_for_issue_goal, run, "Create a roadmap issue")

      expect(prompt).to include("variant Create a roadmap issue #{project.full_name}")
      expect(prompt).to include("Do NOT reply by asking the user to provide the issue type, title, description,")
      expect(prompt).to include("Feature Decomposition")
      expect(prompt).to include("do NOT create any GitHub issue directly")
    end

    it "uses an assigned review-goal variant prompt version" do
      run = create(:agent_run, :review_goal, project: project)
      variant_version = create_ab_test_assignment(
        slug: described_class::REVIEW_GOAL_PROMPT_SLUG,
        agent_run: run,
        variant_template: "review {{base_prompt}} {{repo}} {{pr_number}}"
      )

      prompt = activity.send(:augment_prompt_for_review_goal, run, "Review the branch")

      expect(prompt).to eq("review Review the branch #{project.full_name} #{run.source_pull_request_number}")
      expect(run.reload.prompt_version).to eq(variant_version)
    end

    it "uses an assigned enhance-issue variant prompt version" do
      run = create(:agent_run, :enhance_issue_goal, project: project, issue: issue)
      allow(Knowledge::ContextBundle::Build).to receive(:call)
        .with(issue: issue, project: project, agent_run: run, agent_run_id: run.id)
        .and_return(content: "")
      variant_version = create_ab_test_assignment(
        slug: described_class::ENHANCE_ISSUE_GOAL_PROMPT_SLUG,
        agent_run: run,
        variant_template: "enhance {{base_prompt}} {{repo}} {{issue_number}}"
      )

      prompt = activity.send(:augment_prompt_for_enhance_issue_goal, run, "Improve the issue")

      expect(prompt).to eq("enhance Improve the issue #{project.full_name} #{issue.github_number}")
      expect(run.reload.prompt_version).to eq(variant_version)
    end

    it "keeps using an existing assignment after the test stops running" do
      run = create(:agent_run, :create_issue_goal, project: project)
      variant_version = create_ab_test_assignment(
        slug: described_class::ISSUE_GOAL_PROMPT_SLUG,
        agent_run: run,
        variant_template: "assigned {{base_prompt}} {{repo}}",
        status: "completed"
      )
      variant_version.prompt.update!(active: false)

      prompt = activity.send(:augment_prompt_for_issue_goal, run, "Create a roadmap issue")

      expect(prompt).to include("assigned Create a roadmap issue #{project.full_name}")
      expect(prompt).to include("Do NOT reply by asking the user to provide the issue type, title, description,")
      expect(run.reload.prompt_version).to eq(variant_version)
    end
  end

  describe "#build_runner_order" do
    it "preserves routing-key fallback entries for agent-type runs" do
      api_key = create(:runner_api_key, user: user, api_service_type: "openrouter")
      opencode_runner = create_opencode_runner_entry(
        user: user,
        api_key: api_key,
        name: "Kimi K2.5",
        model: "moonshotai/kimi-k2-0905"
      )
      user.settings.update!(fallback_enabled: true, fallback_runners: [ opencode_runner.routing_key ])

      runners = activity.send(:build_runner_order, agent_run, user.settings)

      expect(runners).to eq([ "claude_code", opencode_runner.routing_key ])
    end

    it "wraps saved fallback order after the active primary runner entry" do
      claude = user.runners.find_by!(runner_key: "claude")
      cursor = create(:runner, user: user, runner_key: "cursor")
      aider = create(:runner, user: user, runner_key: "aider")
      provider_run = create(:agent_run, :with_git_context, project: project,
        issue: create(:issue, project: project), runner: cursor, agent_type: "cursor", container_id: "abc123")
      user.settings.update!(fallback_enabled: true,
        fallback_runners: [ claude.routing_key, cursor.routing_key, aider.routing_key ])

      runners = activity.send(:build_runner_order, provider_run, user.settings)

      expect(runners).to eq([ cursor.routing_key, aider.routing_key, claude.routing_key ])
    end

    it "filters an explicitly selected runner that is no longer container executable" do
      copilot_provider = create(:runner, user: user, runner_key: "copilot")
      codex_provider = create(:runner, user: user, runner_key: "codex")
      agent_run.update!(runner: copilot_provider, agent_type: "copilot")
      user.settings.update!(fallback_enabled: true, fallback_runners: [ codex_provider.routing_key ])
      allow(RunnerSupport).to receive(:container_executable_runner_key?).and_call_original
      allow(RunnerSupport).to receive(:container_executable_runner_key?).with("copilot").and_return(false)

      runners = activity.send(:build_runner_order, agent_run, user.settings)

      expect(runners).to eq([ codex_provider.routing_key, user.runners.find_by!(runner_key: "claude").routing_key ])
      expect(runners).not_to include(copilot_provider.routing_key)
    end

    it "falls back to a runnable default when a saved runner is no longer container executable" do
      copilot_provider = create(:runner, user: user, runner_key: "copilot")
      agent_run.update!(runner: copilot_provider, agent_type: "copilot")
      user.settings.update!(fallback_enabled: false)
      allow(RunnerSupport).to receive(:container_executable_runner_key?).and_call_original
      allow(RunnerSupport).to receive(:container_executable_runner_key?).with("copilot").and_return(false)

      runners = activity.send(:build_runner_order, agent_run, user.settings)

      expect(runners).to eq([ user.runners.find_by!(runner_key: "claude").routing_key ])
      expect(runners).not_to include(copilot_provider.routing_key)
    end

    it "keeps a runnable non-default agent type when no runner is saved" do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude codex])
      agent_run.update!(runner: nil, agent_type: "codex")
      user.settings.update!(fallback_enabled: false)

      runners = activity.send(:build_runner_order, agent_run, user.settings)

      expect(runners).to eq([ "codex" ])
    end

    it "drops stale default-runner entries and keeps the first runnable fallback" do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[codex])
      agent_run.update!(runner: nil, agent_type: "claude_code")
      # Persist a stale saved default plus fallback flag exactly as they could
      # exist from older settings before runner availability changed.
      user.settings.assign_attributes(fallback_enabled: false, default_agent_runner: "claude")
      user.settings.save!(validate: false)

      runners = activity.send(:build_runner_order, agent_run, user.settings)

      expect(runners).to eq([ "codex" ])
    end

    context "with tier-based pre-filtering" do
      it "keeps only runners that support the selected tier" do
        llm_model = create(:llm_model, model_id: "glm-5.1", provider: "zai_coding", tier: "mid")
        create(:model_selection, agent_run: agent_run, llm_model: llm_model, tier: "mid")

        api_key = create(:runner_api_key, user: user, api_service_type: "zai_coding")
        kilocode_runner = create_kilocode_runner_entry(
          user: user,
          api_key: api_key,
          name: "Kilocode GLM 5.1",
          model: "glm-5.1",
          api_provider: "zai_coding"
        )
        codex_runner = create(:runner, user: user, runner_key: "codex")
        user.settings.update!(
          fallback_enabled: true,
          fallback_runners: [ kilocode_runner.routing_key, codex_runner.routing_key ]
        )

        runners = activity.send(:build_runner_order, agent_run, user.settings)

        expect(runners).to include(kilocode_runner.routing_key)
        expect(runners).not_to include(codex_runner.routing_key)
      end

      it "includes direct-outbound runners that support the requested tier with their native model" do
        llm_model = create(:llm_model, model_id: "claude-sonnet-4-6", provider: "anthropic", tier: "mid")
        create(:model_selection, agent_run: agent_run, llm_model: llm_model, tier: "mid")

        api_key = create(:runner_api_key, user: user, api_service_type: "openrouter")
        mismatched_runner = create_opencode_runner_entry(
          user: user, api_key: api_key,
          name: "Kimi K2", model: "moonshotai/kimi-k2-0905"
        )
        codex_runner = create(:runner, user: user, runner_key: "codex")
        user.settings.update!(
          fallback_enabled: true,
          fallback_runners: [ mismatched_runner.routing_key, codex_runner.routing_key ]
        )

        runners = activity.send(:build_runner_order, agent_run, user.settings)

        expect(runners).to include(mismatched_runner.routing_key)
        expect(runners).not_to include(codex_runner.routing_key)
      end

      it "preserves all runners when no model is selected" do
        codex_runner = create(:runner, user: user, runner_key: "codex")
        user.settings.update!(
          fallback_enabled: true,
          fallback_runners: [ codex_runner.routing_key ]
        )

        runners = activity.send(:build_runner_order, agent_run, user.settings)

        expect(runners).to include("claude_code")
        expect(runners).to include(codex_runner.routing_key)
      end

      it "returns no runners when none support the selected tier" do
        llm_model = create(:llm_model, model_id: "exotic-model-99", provider: "exotic_provider", tier: "high")
        create(:model_selection, agent_run: agent_run, llm_model: llm_model, tier: "high")

        user.settings.update!(fallback_enabled: false)

        runners = activity.send(:build_runner_order, agent_run, user.settings)

        expect(runners).to eq([])
      end
    end

    context "with issue-aware provider switching" do
      it "promotes untried runners ahead of previously failed runners" do
        codex_runner = create(:runner, user: user, runner_key: "codex")
        user.settings.update!(fallback_enabled: true, fallback_runners: [ codex_runner.routing_key ])

        # Simulate a prior run for the same issue where claude_code failed
        create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
          runners_attempted: [
            { "runner" => "claude_code", "success" => false, "error_type" => "error" }
          ])

        runners = activity.send(:build_runner_order, agent_run, user.settings)

        # codex (0 failures) should be promoted ahead of claude_code (1 failure)
        expect(runners.first).to eq(codex_runner.routing_key)
        expect(runners).to include("claude_code")
      end

      it "preserves original order when no prior failures exist" do
        codex_runner = create(:runner, user: user, runner_key: "codex")
        user.settings.update!(fallback_enabled: true, fallback_runners: [ codex_runner.routing_key ])

        runners = activity.send(:build_runner_order, agent_run, user.settings)

        # claude_code is the primary; no failures so original order is preserved
        expect(runners.first).to eq("claude_code")
        expect(runners.second).to eq(codex_runner.routing_key)
      end

      it "does not reorder when there is only one runner" do
        user.settings.update!(fallback_enabled: false)

        create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
          runners_attempted: [
            { "runner" => "claude_code", "success" => false, "error_type" => "error" }
          ])

        runners = activity.send(:build_runner_order, agent_run, user.settings)

        expect(runners.size).to eq(1)
      end

      it "does not reorder for runs without an issue" do
        codex_runner = create(:runner, user: user, runner_key: "codex")
        user.settings.update!(fallback_enabled: true, fallback_runners: [ codex_runner.routing_key ])

        issueless_run = create(:agent_run, :with_custom_prompt, project: project, issue: nil,
          container_id: "xyz789")
        allow(AgentRun).to receive(:find).with(issueless_run.id).and_return(issueless_run)

        create(:agent_run, :failed, project: project, issue: nil, goal: "create_pr",
          custom_prompt: "some prompt",
          runners_attempted: [
            { "runner" => "claude_code", "success" => false, "error_type" => "error" }
          ])

        runners = activity.send(:build_runner_order, issueless_run, user.settings)

        # No issue_id means no reordering — claude_code stays first
        expect(runners.first).to eq("claude_code")
      end

      it "uses stable sort: runners with equal failure counts keep original order" do
        codex_runner = create(:runner, user: user, runner_key: "codex")
        aider_runner = create(:runner, user: user, runner_key: "aider")
        user.settings.update!(
          fallback_enabled: true,
          fallback_runners: [ codex_runner.routing_key, aider_runner.routing_key ]
        )

        # Both claude_code and codex have failed once; aider is untried
        create(:agent_run, :failed, project: project, issue: issue, goal: "create_pr",
          runners_attempted: [
            { "runner" => "claude_code", "success" => false, "error_type" => "error" },
            { "runner" => "codex", "success" => false, "error_type" => "error" }
          ])

        runners = activity.send(:build_runner_order, agent_run, user.settings)

        # aider (0 failures) should come first
        expect(runners.first).to eq(aider_runner.routing_key)
        # claude_code and codex (1 failure each) follow in their original order
        expect(runners[1]).to eq("claude_code")
        expect(runners[2]).to eq(codex_runner.routing_key)
      end
    end
  end

  def build_opencode_context(user, api_provider: "openrouter", model: "moonshotai/kimi-k2-0905", service_type: "openrouter", api_key: "sk-openrouter-secret")
    provider_api_key = create(:runner_api_key, user: user, api_service_type: service_type, api_key: api_key)
    runner = create_opencode_provider_entry(user: user, api_key: provider_api_key, name: nil, model: model, api_provider: api_provider)

    described_class::CommandContext.new(
      runner_candidate: runner.routing_key,
      runner: "opencode",
      user: user
    )
  end

  def build_kilocode_context(user)
    api_key = create(:runner_api_key, user: user, api_service_type: "anthropic", api_key: "sk-anthropic-secret")
    runner = create(
      :runner,
      user: user,
      auth_type: "api_key",
      provider_api_key: api_key,
      runner_key: "kilocode",
      name: "Kilocode Claude",
      config: { "kilocode" => { "api_provider" => "anthropic", "model" => "claude-sonnet-4-20250514" } }
    )

    described_class::CommandContext.new(
      runner_candidate: runner.routing_key,
      runner: "kilocode",
      user: user
    )
  end

  def expect_opencode_fallback_execution(opencode_runner)
    call_count = 0
    expect(container_service).to receive(:execute).twice do |command, **opts|
      call_count += 1
      if call_count == 1
        rate_limit_failure
      else
        expect(command[0..5]).to eq([ "env", "-u", "OPENAI_HEADER_X_AGENT_RUN_ID", "-u", "OPENAI_HEADER_X_PROXY_TOKEN", "opencode" ])
        expect(command[6]).to eq("run")
        expect(opts[:env]).to include("OPENAI_BASE_URL" => "https://openrouter.ai/api/v1")
        expect(opts[:preparation].file_writes.first.path).to eq("~/.config/opencode/opencode.json")
        exec_success
      end
    end

    result = activity.execute(agent_run_id: agent_run.id)

    expect(result[:success]).to be true
    expect(result[:final_runner]).to eq(opencode_runner.routing_key)
    expect(agent_run.reload.final_runner).to eq(opencode_runner.routing_key)
  end

  def expect_opencode_runtime_execute_calls(execute_calls)
    expect(execute_calls.length).to eq(3)
    expect(execute_calls.second.first[0..6]).to eq([ "env", "-u", "OPENAI_HEADER_X_AGENT_RUN_ID", "-u", "OPENAI_HEADER_X_PROXY_TOKEN", "opencode", "run" ])
    expect(execute_calls.third.first[0..6]).to eq([ "env", "-u", "OPENAI_HEADER_X_AGENT_RUN_ID", "-u", "OPENAI_HEADER_X_PROXY_TOKEN", "opencode", "run" ])
    expect(execute_calls.second.second[:env]).to include("OPENAI_BASE_URL" => "https://openrouter.ai/api/v1")
    expect(execute_calls.third.second[:env]).to include("OPENAI_BASE_URL" => "https://openrouter.ai/api/v1")
    second_config = JSON.parse(execute_calls.second.second[:preparation].file_writes.first.content)
    third_config = JSON.parse(execute_calls.third.second[:preparation].file_writes.first.content)

    expect(second_config).to include("model" => "moonshotai/kimi-k2-0905")
    expect(second_config).not_to have_key("provider")
    expect(third_config).to include("model" => "moonshotai/kimi-k2-0905")
    expect(third_config).not_to have_key("provider")
  end

  def expect_resolved_model_attempts(agent_run, opencode_runner)
    expect(agent_run.runners_attempted).to contain_exactly(
      hash_including(
        "runner" => "claude_code",
        "success" => false,
        "error_type" => "preflight_timeout",
        "resolved_model_id" => "claude-sonnet-4-6",
        "resolution_source" => "default"
      ),
      hash_including(
        "runner" => opencode_runner.routing_key,
        "success" => true,
        "resolved_model_id" => "moonshotai/kimi-k2-0905",
        "resolved_provider_id" => opencode_runner.id,
        "resolution_source" => "runner"
      )
    )
  end

  def expect_timeout_fallback_recovery(agent_run)
    expect(agent_run.runners_attempted).to contain_exactly(
      hash_including(
        "runner" => "claude_code",
        "success" => false,
        "error_type" => "timeout",
        "diagnostics" => hash_including(
          "timeout_type" => "wall_clock",
          "elapsed_seconds" => 901.2,
          "effective_timeout_seconds" => 3600
        )
      ),
      hash_including("runner" => "cursor", "success" => true)
    )
    expect(agent_run.runner_switches).to eq(1)
    expect(agent_run.container_id).to eq("reprovisioned-123")
    expect(git_ops).to have_received(:clone_and_restore_branch).with(
      branch_name: agent_run.branch_name,
      base_commit_sha: agent_run.base_commit_sha,
      pull_request_number: agent_run.source_pull_request_number
    )
    expect(git_ops).to have_received(:install_artifact_excludes)
    expect(git_ops).to have_received(:install_git_hooks)
    expect(git_ops).to have_received(:install_co_author_hook)
  end

  def expect_same_provider_rate_limit_fallback_execution(fallback_provider)
    logger = instance_double(ActiveSupport::Logger, info: nil, warn: nil, error: nil)
    allow(activity).to receive(:logger).and_return(logger)

    allow(container_service).to receive(:execute).twice do |command, **opts|
      if command.first == "claude"
        rate_limit_failure
      else
        expect(command[0..1]).to eq(%w[sh -c])
        expect(command[2]).to include('ANTHROPIC_BASE_URL="$PAID_PROXY_URL/api/proxy/anthropic"')
        expect(command[2]).to include('ANTHROPIC_HEADER_X_AGENT_RUN_ID="$AGENT_RUN_ID"')
        expect(command[2]).to include('ANTHROPIC_HEADER_X_PROXY_TOKEN="$PROXY_TOKEN"')
        expect(command[2]).to include('ANTHROPIC_API_KEY="paid-run:$AGENT_RUN_ID:$PROXY_TOKEN"')
        expect(command[2]).not_to include("sk-fallback-secret")
        expect(opts[:env]).to include("PAID_PROVIDER_ID" => fallback_provider.id.to_s)
        exec_success
      end
    end
    allow(git_ops).to receive(:has_changes_since?).and_return(false)

    result = activity.execute(agent_run_id: agent_run.id)

    expect(result[:success]).to be true
    expect(result[:final_runner]).to eq(fallback_provider.routing_key)
    expect(agent_run.reload.final_runner).to eq(fallback_provider.routing_key)
    expect(agent_run.runners_attempted.map { |attempt| attempt["runner"] }).to eq([ "claude_code", fallback_provider.routing_key ])
    expect(agent_run.runner_switches).to eq(1)
    expect(logger).to have_received(:info).with(
      hash_including(
        message: "agent_execution.rate_limit_fallback_available",
        runner: "claude",
        agent_run_id: agent_run.id,
        fallback_runners: [ fallback_provider.routing_key ]
      )
    )
  end

  def create_claude_rate_limit_fallback_provider(api_key: "sk-fallback-secret")
    create(
      :runner,
      :rate_limit_fallback,
      user: user,
      runner_key: "claude",
      provider_api_key: create(:runner_api_key, user: user, api_service_type: "anthropic", api_key: api_key),
      enabled_for_agent_runs: true,
      enabled_for_fallback: true,
      name: "Claude API Key"
    )
  end

  def create_opencode_runner_entry(user:, api_key:, name:, model:, api_provider: "openrouter")
    create(
      :runner,
      user: user,
      runner_key: "opencode",
      auth_type: "api_key",
      provider_api_key: api_key,
      name: name || "",
      enabled_for_agent_runs: true,
      config: { "opencode" => { "api_provider" => api_provider, "model" => model } }
    ).tap do |runner|
      runner.update!(tier_models: LlmModel::TIERS.to_h do |tier|
        [ tier, { "model_id" => model, "provider_id" => runner.id } ]
      end)
    end
  end

  alias_method :create_opencode_provider_entry, :create_opencode_runner_entry

  def create_openrouter_free_runner(user:, api_key:, model:)
    create(
      :runner,
      user: user,
      runner_key: "openrouter_free",
      auth_type: "api_key",
      provider_api_key: api_key,
      tier_model_ids: LlmModel::TIERS.index_with { model }
    ).tap do |runner|
      runner.update!(tier_models: LlmModel::TIERS.index_with { { "model_id" => model, "provider_id" => runner.id } })
    end
  end

  def build_openrouter_free_run(project:, model:, data_classification:)
    run = create(:agent_run, :with_git_context, project: project, issue: create(:issue, project: project))
    project_stub = Struct.new(:data_classification).new(data_classification)
    selection_stub = Struct.new(:tier, :llm_model).new("mid", model)
    allow(run).to receive_messages(project: project_stub, model_selection: selection_stub)
    run
  end

  def create_kilocode_runner_entry(user:, api_key:, name:, model:, api_provider:)
    create(
      :runner,
      user: user,
      auth_type: "api_key",
      provider_api_key: api_key,
      runner_key: "kilocode",
      name: name,
      config: { "kilocode" => { "api_provider" => api_provider, "model" => model } },
      tier_models: {
        "mid" => { "model_id" => model, "provider_id" => 17 }
      }
    )
  end

  def create_low_only_opencode_runner(user:, name:)
    api_key = create(:runner_api_key, user: user, api_service_type: "openrouter")
    create_opencode_runner_entry(
      user: user,
      api_key: api_key,
      name: name,
      model: "moonshotai/kimi-k2-0905"
    ).tap do |runner|
      runner.update!(tier_models: {
        "low" => { "model_id" => "moonshotai/kimi-k2-0905", "provider_id" => runner.id }
      })
    end
  end

  def configure_single_compatible_opencode_runner(agent_run:, user:)
    llm_model = create(:llm_model, model_id: "moonshotai/kimi-k2-0905", provider: "openrouter")
    create(:model_selection, agent_run: agent_run, llm_model: llm_model)

    allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude codex opencode])

    api_key = create(:runner_api_key, user: user, api_service_type: "openrouter")
    kimi_runner = create_opencode_runner_entry(
      user: user,
      api_key: api_key,
      name: "Kimi K2",
      model: "moonshotai/kimi-k2-0905"
    )
    codex_runner = create(:runner, user: user, runner_key: "codex")

    user.settings.update!(
      fallback_enabled: true,
      fallback_runners: [ kimi_runner.routing_key, codex_runner.routing_key ]
    )

    kimi_runner
  end

  def expect_change_detection_retry_logs(logger, operation:)
    expect(logger).to have_received(:warn).with(hash_including(
      message: "agent_execution.change_detection_retry",
      operation: operation,
      attempt: 1
    ))
    expect(logger).to have_received(:warn).with(hash_including(
      message: "agent_execution.change_detection_retry",
      operation: operation,
      attempt: 2
    ))
    expect(logger).to have_received(:error).with(hash_including(
      message: "agent_execution.change_detection_failed",
      operation: operation,
      attempt: 3,
      transient: true
    ))
  end

  def expect_non_retryable_post_run_error(error, operation:)
    expect(error).to be_a(Temporalio::Error::ApplicationError)
    expect(error.type).to eq(Activities::RunAgentActivity::POST_RUN_BOOKKEEPING_ERROR_TYPE)
    expect(error.non_retryable).to be(true)
    expect(error.message).to include("Post-run #{operation} failed after 3 attempts")
  end

  def codex_auth_expired_output
    Containers::Provision::Result.failure(
      error: "exit 1",
      stdout: "",
      stderr: <<~STDERR,
        ERROR codex_core::auth: Failed to refresh token: 401 Unauthorized
        "message": "Your refresh token has already been used to generate a new access token. Please try signing in again."
        "code": "refresh_token_reused"
        ERROR codex_core::auth: Failed to refresh token: Your access token could not be refreshed because your refresh token was already used. Please log out and sign in again.
      STDERR
      exit_code: 1
    )
  end

  def expect_preflight_failure_log(activity, agent_run_id, runner:, reason:)
    expect(activity.send(:logger)).to have_received(:warn).with(
      hash_including(
        message: "agent_execution.preflight_failed",
        runner: runner,
        agent_run_id: agent_run_id,
        reason: include(reason)
      )
    )
  end

  def wrap_error(inner_error, message = "wrapped failure")
    begin
      raise inner_error
    rescue => e
      raise StandardError, "#{message}: #{e.class}: #{e.message}"
    end
  rescue => wrapped
    wrapped
  end

  def stub_reconnect_not_found_on_second_attempt
    attempts = 0
    allow(Containers::Provision).to receive(:reconnect) do
      attempts += 1
      if attempts == 2
        raise wrap_error(
          Containers::Provision::ProvisionError.new("Container #{agent_run.container_id} not found")
        )
      end
      container_service
    end
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
             satisfy { |cmd| cmd.is_a?(Array) },
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

      it "returns review_threads_already_addressed when the agent emits the marker" do
        marker_success = Containers::Provision::Result.success(
          stdout: "Reviewed the branch.\n#{Prompts::BuildForPr::ALREADY_ADDRESSED_MARKER}\n",
          stderr: "",
          exit_code: 0
        )
        allow(container_service).to receive(:execute).and_return(marker_success)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:review_threads_already_addressed]).to be(true)
        expect(result[:has_changes]).to be(false)
      end

      it "succeeds and logs an informational message when runner has no output and no changes" do
        no_output_success = Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0)
        allow(container_service).to receive(:execute).and_return(no_output_success)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
        expect(result[:has_changes]).to be false
        expect(agent_run.reload.agent_run_logs.where(
          log_type: "system",
          content: "Runner completed with no output and no changes"
        )).to exist
      end

      it "succeeds when runner output is binary encoded" do
        binary_success = Containers::Provision::Result.success(
          stdout: "Done \xFF".b,
          stderr: "",
          exit_code: 0
        )
        allow(container_service).to receive(:execute).and_return(binary_success)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
        expect(result[:final_runner]).to eq("claude_code")
        expect(agent_run.reload.final_runner).to eq("claude_code")
        expect(agent_run.runners_attempted.map { |attempt| attempt["runner"] }).to eq([ "claude_code" ])
      end

      context "when agent-harness can parse token usage from CLI output" do
        let(:agent_run) { create(:agent_run, :kilocode, :with_git_context, project: project, issue: issue, container_id: "abc123") }
        let(:exec_success) do
          Containers::Provision::Result.success(
            stdout: [
              { type: "text", text: "Done" }.to_json,
              { type: "usage", usage: { input_tokens: 1200, output_tokens: 300, total_tokens: 1500 } }.to_json
            ].join("\n"),
            stderr: "",
            exit_code: 0
          )
        end

        it "records run summary usage and updates billable run aggregates" do
          allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

          activity.execute(agent_run_id: agent_run.id)

          usages = agent_run.token_usages.order(:request_type)
          expect(usages.pluck(:request_type, :input_tokens, :output_tokens)).to eq([
            [ "run_delta", 1200, 300 ],
            [ "run_summary", 1200, 300 ]
          ])
          expect(agent_run.reload.tokens_input).to eq(1200)
          expect(agent_run.tokens_output).to eq(300)
        end

        it "logs and skips token tracking when harness parsing fails" do
          logger = instance_double(ActiveSupport::Logger, warn: nil, error: nil, info: nil)

          allow(activity).to receive(:logger).and_return(logger)
          allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)
          allow(activity).to receive(:parse_harness_response).and_raise(JSON::ParserError, "bad output")

          result = activity.execute(agent_run_id: agent_run.id)

          expect(result[:success]).to be true
          expect(agent_run.token_usages).to be_empty
          expect(logger).to have_received(:warn).with(
            hash_including(
              message: "agent_execution.token_usage_parse_failed",
              agent_run_id: agent_run.id,
              runner: "kilocode",
              error_class: "JSON::ParserError",
              error: "bad output"
            )
          )
        end

        it "raises when token usage persistence fails after parsing succeeds" do
          allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)
          allow(AgentRuns::TrackHarnessTokens).to receive(:call).and_raise(ActiveRecord::RecordInvalid.new(agent_run))

          expect {
            activity.execute(agent_run_id: agent_run.id)
          }.to raise_error(ActiveRecord::RecordInvalid)
        end

        it "does not subtract proxy usage from previous failed runner attempts" do
          TokenUsage.create!(
            agent_run: agent_run,
            request_type: "agent",
            input_tokens: 700,
            output_tokens: 100,
            cost_cents: 1,
            llm_model: "claude-sonnet-4",
            created_at: 2.hours.ago,
            updated_at: 2.hours.ago
          )
          allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

          activity.execute(agent_run_id: agent_run.id)

          expect(agent_run.token_usages.find_by!(request_type: "run_delta")).to have_attributes(
            input_tokens: 1200,
            output_tokens: 300
          )
          expect(agent_run.reload.tokens_input).to eq(1200)
          expect(agent_run.tokens_output).to eq(300)
        end
      end

      it "retries transient commit failures before checking for changes" do
        commit_attempts = 0

        allow(activity).to receive(:sleep)
        allow(git_ops).to receive(:commit_uncommitted_changes) do
          commit_attempts += 1
          raise Docker::Error::DockerError, "docker unavailable" if commit_attempts == 1

          true
        end
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(true)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(git_ops).to have_received(:commit_uncommitted_changes).twice
        expect(activity).to have_received(:sleep).with(0.25)
      end

      it "retries wrapped container exec failures before checking for changes" do
        commit_attempts = 0

        allow(activity).to receive(:sleep)
        allow(git_ops).to receive(:commit_uncommitted_changes) do
          commit_attempts += 1
          if commit_attempts == 1
            raise wrap_error(
              Containers::Provision::ExecutionError.new("Docker exec error: Connection reset")
            )
          end

          true
        end
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(true)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(git_ops).to have_received(:commit_uncommitted_changes).twice
        expect(activity).to have_received(:sleep).with(0.25)
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

      it "retries transient change-detection failures before succeeding" do
        change_attempts = 0

        allow(activity).to receive(:sleep)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123") do
          change_attempts += 1
          raise Docker::Error::DockerError, "docker unavailable" if change_attempts == 1

          true
        end

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(git_ops).to have_received(:has_changes_since?).twice
        expect(activity).to have_received(:sleep).with(0.25)
      end

      it "retries socket-level container reconnect failures before succeeding" do
        change_attempts = 0

        allow(activity).to receive(:sleep)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123") do
          change_attempts += 1
          raise Errno::ECONNREFUSED, "Connection refused" if change_attempts == 1

          true
        end

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(git_ops).to have_received(:has_changes_since?).twice
        expect(activity).to have_received(:sleep).with(0.25)
      end

      it "retries wrapped socket-level container reconnect failures before succeeding" do
        change_attempts = 0

        allow(activity).to receive(:sleep)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123") do
          change_attempts += 1
          raise wrap_error(Errno::ECONNREFUSED.new("Connection refused")) if change_attempts == 1

          true
        end

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(git_ops).to have_received(:has_changes_since?).twice
        expect(activity).to have_received(:sleep).with(0.25)
      end

      it "retries transient fallback change-detection failures before succeeding" do
        change_attempts = 0

        allow(activity).to receive(:sleep)
        allow(git_ops).to receive(:head_sha).and_raise(StandardError, "container not ready")
        allow(git_ops).to receive(:commit_uncommitted_changes).and_return(false)
        allow(git_ops).to receive(:has_changes?) do
          change_attempts += 1
          raise Docker::Error::DockerError, "docker unavailable" if change_attempts == 1

          true
        end
        allow(git_ops).to receive(:has_changes_since?)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(git_ops).to have_received(:has_changes?).twice
        expect(git_ops).not_to have_received(:has_changes_since?)
        expect(activity).to have_received(:sleep).with(0.25)
      end

      it "retries wrapped container reconnect failures before succeeding" do
        attempts = 0

        allow(activity).to receive(:sleep)
        allow(Containers::Provision).to receive(:reconnect) do
          attempts += 1
          if attempts == 2
            raise wrap_error(
              Containers::Provision::ProvisionError.new("Failed to reconnect to container: connection reset")
            )
          end

          container_service
        end
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(true)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(Containers::Provision).to have_received(:reconnect).at_least(:twice)
        expect(activity).to have_received(:sleep).with(0.25)
      end

      it "does not retry permanent container-not-found reconnect failures" do
        allow(activity).to receive(:sleep)
        stub_reconnect_not_found_on_second_attempt

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          aggregate_failures do
            expect(error.type).to eq("PostRunBookkeepingFailed")
            expect(error.non_retryable).to be(true)
            expect(error.message).to include("Post-run commit_uncommitted_changes failed after 1 attempts")
            expect(error.message).to include("Containers::Provision::ProvisionError")
            expect(error.message).to include("not found")
          end
        }
        expect(activity).not_to have_received(:sleep)
        expect(Containers::Provision).to have_received(:reconnect).twice
      end

      it "raises a non-retryable ApplicationError when change detection keeps failing after transient retries" do
        logger = instance_double(ActiveSupport::Logger, warn: nil, error: nil, info: nil)
        change_attempts = 0

        allow(activity).to receive(:logger).and_return(logger)
        allow(activity).to receive(:sleep)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123") do
          change_attempts += 1
          raise Docker::Error::DockerError, "docker unavailable"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect_non_retryable_post_run_error(error, operation: "check_for_changes")
          expect(error.message).to include("Docker::Error::DockerError: docker unavailable")
        }

        expect(change_attempts).to eq(3)
        expect_change_detection_retry_logs(logger, operation: "check_for_changes")
      end

      it "raises a non-retryable ApplicationError when auto-commit keeps failing after transient retries" do
        logger = instance_double(ActiveSupport::Logger, warn: nil, error: nil, info: nil)
        commit_attempts = 0

        allow(activity).to receive(:logger).and_return(logger)
        allow(activity).to receive(:sleep)
        allow(git_ops).to receive(:commit_uncommitted_changes) do
          commit_attempts += 1
          raise Errno::ECONNREFUSED, "Connection refused"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect_non_retryable_post_run_error(error, operation: "commit_uncommitted_changes")
          expect(error.message).to include("Errno::ECONNREFUSED")
        }

        expect(commit_attempts).to eq(3)
        expect_change_detection_retry_logs(logger, operation: "commit_uncommitted_changes")
      end

      it "records the final_runner on success" do
        allow(git_ops).to receive(:has_changes_since?).and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:final_runner]).to eq("claude_code")
        expect(agent_run.reload.final_runner).to eq("claude_code")
      end

      it "heartbeats during post-run bookkeeping after runner execution" do
        allow(git_ops).to receive(:has_changes_since?).and_return(false)

        allow(activity).to receive(:with_periodic_heartbeat).and_call_original

        activity.execute(agent_run_id: agent_run.id)

        expect(activity).to have_received(:with_periodic_heartbeat)
          .with("post_run_bookkeeping", "claude_code")
        expect(activity).not_to have_received(:with_periodic_heartbeat)
          .with("post_run_bookkeeping", "claude_code", agent_run: agent_run)
      end

      it "returns the selected runner when pre-commit requirements block completion" do
        allow(activity).to receive(:evaluate_pre_commit_requirements).and_return(
          { blocking: true, results: [ { name: "rubocop", status: "failed" } ] }
        )
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(true)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result).to include(
          success: false,
          has_changes: true,
          output_present: true,
          final_runner: "claude_code",
          error: "pre_commit_requirements_failed"
        )
        expect(agent_run.reload.final_runner).to eq("claude_code")
      end
    end

    context "when agent fails in container" do
      before do
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute).and_return(exec_failure)
      end

      it "raises AllProvidersExhausted when all runners fail" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)
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

    shared_examples "externally cancelled run" do |params|
      before do
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute) do
          AgentRun.where(id: agent_run.id).update_all(
            status: "timeout",
            error_message: params.fetch(:error_message),
            completed_at: Time.current
          )
          exec_failure
        end
      end

      it "does not increment the runner circuit-breaker failure_count" do
        state = user.runner_states.create!(runner_name: "claude", failure_count: 0, circuit_state: "closed")

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError)

        expect(state.reload.failure_count).to eq(0)
        expect(state.circuit_state).to eq("closed")
      end

      it "records the runner attempt as cancelled_by_cleanup" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError)

        attempts = agent_run.reload.runners_attempted
        expect(attempts.last["error_type"]).to eq("cancelled_by_cleanup")
        expect(attempts.last["success"]).to be false
      end

      it "preserves the cleanup error_message and timeout status on the run" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to start_with(params.fetch(:prefix))
      end

      it "stops iterating runners instead of attempting fallbacks" do
        user.settings.update!(fallback_enabled: true)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError)

        expect(agent_run.reload.runners_attempted.size).to eq(1)
      end

      it "does not enqueue ProcessRunQueueJob" do
        expect(ProcessRunQueueJob).not_to receive(:perform_later)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError)
      end
    end

    context "when the run is cancelled by dev:cleanup mid-execution" do
      it_behaves_like "externally cancelled run",
        prefix: AgentRun::STALE_CLEANUP_ERROR_PREFIX,
        error_message: "#{AgentRun::STALE_CLEANUP_ERROR_PREFIX}: process was restarted"
    end

    context "when the run is cancelled by StaleRunDetectorJob mid-execution" do
      it_behaves_like "externally cancelled run",
        prefix: AgentRun::STALE_DETECTOR_ERROR_PREFIX,
        error_message: "#{AgentRun::STALE_DETECTOR_ERROR_PREFIX}: stuck in 'running' beyond timeout threshold"
    end

    context "when agent hits rate limit (single runner)" do
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
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload

        expect(agent_run.status).to eq("failed")
        expect(agent_run.error_message).to include("All runners exhausted")
        expect(agent_run.error_message).not_to include("rate limited")

        provider_state = user.runner_states.find_by(runner_name: "claude")
        expect(provider_state&.rate_limited_until).to be_nil
      end

      before do
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute).and_return(rate_limit_output)
      end

      it "marks the agent run as rate_limited" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.rate_limited_until).to be_present
        expect(agent_run.error_message).to include("rate limited")
      end

      it "detects Claude-specific usage limit error" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        expect(agent_run.reload.status).to eq("rate_limited")
      end

      it "marks the agent run as rate_limited when runner output is binary encoded" do
        binary_rate_limit_output = Containers::Provision::Result.failure(
          error: "rate limit",
          stdout: "",
          stderr: "You're out of extra usage \xB7 resets 5am (UTC)".b,
          exit_code: 1
        )
        allow(container_service).to receive(:execute).and_return(binary_rate_limit_output)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.rate_limited_until).to be_present
        expect(agent_run.error_message).to include("rate limited")
      end

      it "does not classify echoed prompt text as a rate limit" do
        echoed_prompt = <<~PROMPT
          Investigate why the secrets proxy returns 429 for token usage limits.
          Confirm whether the runner itself is actually rate limited.
        PROMPT
        prompt_echo_output = Containers::Provision::Result.failure(
          error: "killed", stdout: "", stderr: echoed_prompt, exit_code: 137
        )

        expect_prompt_echo_to_fail_without_rate_limit!(prompt: echoed_prompt, output: prompt_echo_output)
      end

      it "ignores prompt echoes wrapped in common prefixes" do
        echoed_prompt = <<~PROMPT
          Investigate why the secrets proxy returns 429 for token usage limits.
          Confirm whether the runner itself is actually rate limited.
        PROMPT
        prefixed_prompt_echo_output = Containers::Provision::Result.failure(
          error: "killed",
          stdout: "",
          stderr: <<~OUTPUT,
            user
            > Investigate why the secrets proxy returns 429 for token usage limits.
            > Confirm whether the runner itself is actually rate limited.
          OUTPUT
          exit_code: 137
        )

        expect_prompt_echo_to_fail_without_rate_limit!(prompt: echoed_prompt, output: prefixed_prompt_echo_output)
      end
    end

    context "when codex auth has expired" do
      let(:agent_run) do
        create(:agent_run, :with_git_context,
          project: project,
          issue: issue,
          agent_type: "codex",
          container_id: "abc123")
      end

      before do
        user.runners.find_or_create_by!(runner_key: "cursor")
        user.settings.update!(fallback_enabled: true, fallback_runners: [ "cursor" ])
        allow(activity).to receive(:logger).and_return(instance_double(ActiveSupport::Logger, info: nil, warn: nil, error: nil))
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        # Re-enable the real preflight method; the shared before stubs it away.
        allow(activity).to receive(:run_runner_preflight!).and_call_original
        # By default harness preflight passes (no-op); individual tests override.
        allow(activity).to receive(:run_harness_preflight!)
      end

      it "falls back when harness preflight detects expired auth" do
        codex_harness = instance_double(AgentHarness::Providers::Codex)
        # Only codex has a harness runner; cursor returns nil (no harness preflight).
        preflight_calls = 0
        allow(activity).to receive(:preflight_provider_instance) { (preflight_calls += 1) == 1 ? codex_harness : nil }
        allow(activity).to receive(:logger).and_return(instance_double(ActiveSupport::Logger, info: nil, warn: nil, error: nil))
        allow(activity).to receive(:run_harness_preflight!).and_raise(
          Activities::RunAgentActivity::RunnerExecutionError, "Preflight check failed: Auth token expired: refresh_token_reused"
        )
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive(:commit_uncommitted_changes).and_return(false)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(result).to include(success: true, final_runner: "cursor")
        expect(agent_run.runners_attempted).to contain_exactly(
          hash_including("runner" => "codex", "success" => false, "error_type" => "error"),
          hash_including("runner" => "cursor", "success" => true)
        )
        expect(agent_run.runner_switches).to eq(1)
        # Cursor smoke exec + cursor main exec (codex smoke skipped: harness preflight raised first).
        expect(container_service).to have_received(:execute).twice
      end

      it "falls back when smoke exec detects expired auth after harness preflight passes" do
        # codex smoke exec → auth expired, cursor smoke exec → success, cursor main exec → success
        allow(container_service).to receive(:execute).and_return(codex_auth_expired_output, exec_success, exec_success)
        allow(git_ops).to receive(:commit_uncommitted_changes).and_return(false)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(result).to include(success: true, final_runner: "cursor")
        expect(agent_run.status).to eq("running")
        expect(agent_run.runners_attempted).to contain_exactly(
          hash_including("runner" => "codex", "success" => false, "error_type" => "error"),
          hash_including("runner" => "cursor", "success" => true)
        )
        expect(agent_run.runner_switches).to eq(1)
        expect(container_service).to have_received(:execute).exactly(3).times
        expect_preflight_failure_log(activity, agent_run.id, runner: "codex", reason: "refresh_token_reused")
      end

      it "marks the run as auth_expired when the main execution fails after preflight succeeds" do
        allow(container_service).to receive(:execute).and_return(exec_success, codex_auth_expired_output)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("auth_expired")
        expect(agent_run.auth_provider).to eq("codex")
        expect(agent_run.error_message).to include("refresh_token_reused")
        expect(agent_run.runners_attempted).to contain_exactly(
          hash_including("runner" => "codex", "success" => false, "error_type" => "auth_expired")
        )
        expect(agent_run.runner_switches).to eq(0)
        expect(container_service).to have_received(:execute).twice
      end

      it "treats generic refresh failures during preflight as ordinary runner errors" do
        generic_refresh_failure = Containers::Provision::Result.failure(
          error: "exit 1",
          stdout: "",
          stderr: "ERROR codex_core::auth: Failed to refresh token: 500 Internal Server Error",
          exit_code: 1
        )
        # codex smoke exec → failure, cursor smoke exec → success, cursor main exec → success
        allow(container_service).to receive(:execute).and_return(generic_refresh_failure, exec_success, exec_success)
        allow(git_ops).to receive(:commit_uncommitted_changes).and_return(false)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(result).to include(success: true, final_runner: "cursor")
        expect(agent_run.status).to eq("running")
        expect(agent_run.runners_attempted).to contain_exactly(
          hash_including("runner" => "codex", "success" => false, "error_type" => "error"),
          hash_including("runner" => "cursor", "success" => true)
        )
        expect(agent_run.runner_switches).to eq(1)
        expect(container_service).to have_received(:execute).exactly(3).times
      end

      it "uses a short timeout for codex preflight" do
        allow(container_service).to receive(:execute).and_return(codex_auth_expired_output, exec_success)
        allow(git_ops).to receive(:commit_uncommitted_changes).and_return(false)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

        activity.execute(agent_run_id: agent_run.id)

        expect(container_service).to have_received(:execute).with(
          array_including("Reply with exactly OK."),
          hash_including(
            timeout: described_class::PREFLIGHT_TIMEOUT_SECONDS,
            idle_timeout: described_class::PREFLIGHT_TIMEOUT_SECONDS
          )
        )
      end

      it "uses a longer timeout for direct-outbound provider preflight" do
        opencode_provider = create_opencode_provider_for(user)
        allow(container_service).to receive(:execute).and_return(exec_success)

        run_direct_outbound_preflight(
          activity: activity,
          agent_run: agent_run,
          container_service: container_service,
          provider: opencode_provider,
          user: user
        )

        expect(container_service).to have_received(:execute).with(
          %w[echo ok],
          hash_including(
            timeout: described_class::DIRECT_OUTBOUND_PREFLIGHT_TIMEOUT_SECONDS,
            idle_timeout: described_class::DIRECT_OUTBOUND_PREFLIGHT_TIMEOUT_SECONDS
          )
        )
      end

      it "marks the runner rate-limited when preflight surfaces an insufficient credits error" do
        opencode_provider = create_opencode_provider_for(user)
        credit_error = Containers::Provision::Result.success(
          stdout: "", stderr: "Error: Insufficient Balance", exit_code: 0
        )
        allow(container_service).to receive(:execute).and_return(credit_error)

        expect {
          run_direct_outbound_preflight(
            activity: activity,
            agent_run: agent_run,
            container_service: container_service,
            provider: opencode_provider,
            user: user
          )
        }.to raise_error(described_class::ProviderRateLimitError, /credit\/quota exhausted/) do |error|
          expect(error.reset_at).to be_within(2.minutes).of(
            described_class::INSUFFICIENT_CREDITS_BACKOFF.from_now
          )
        end
      end

      it "opens the runner circuit after three consecutive preflight timeouts and skips later runs during cooldown" do
        runner = user.runners.find_by!(runner_key: "claude")
        user.settings.update!(circuit_breaker_failure_threshold: 10)
        allow(activity).to receive(:run_agent_with_runner).and_raise(
          described_class::PreflightTimeoutError,
          "Preflight check failed: Runner smoke preflight timed out after 30s"
        )

        trip_runner_circuit_with_preflight_timeouts(activity: activity, project: project, runner: runner)

        state = user.runner_states.find_by!(runner_name: runner.state_key)
        expect(state).to be_circuit_open

        skipped_run = create_runner_backed_agent_run(project: project, runner: runner)

        expect(activity).not_to receive(:run_agent_with_runner)
        expect_all_runners_exhausted(activity: activity, agent_run: skipped_run)

        expect(skipped_run.reload.runners_attempted).to include(
          hash_including(
            "error_type" => "unavailable",
            "error_message" => "Skipped because runner circuit is open"
          )
        )
      end

      it "marks the agent run as rate_limited (not failed) when every runner is circuit-open" do
        user.settings.update!(
          fallback_enabled: false,
          fallback_runners: [],
          circuit_breaker_failure_threshold: 10,
          circuit_breaker_timeout_seconds: 600
        )
        runner = user.runners.find_by!(runner_key: "claude")
        create_open_runner_state(user: user, runner: runner, opened_at: Time.current)

        skipped_run = create_runner_backed_agent_run(project: project, runner: runner)
        expect(activity).not_to receive(:run_agent_with_runner)
        expect_all_runners_exhausted(activity: activity, agent_run: skipped_run)

        skipped_run.reload
        expect(skipped_run.status).to eq("rate_limited")
        expect(skipped_run.error_message).to include("circuit open")
        expect(skipped_run.rate_limited_until).to be_within(2.minutes).of(10.minutes.from_now)
      end

      it "reopens a half-open runner circuit when the recovery preflight times out" do
        runner = user.runners.find_by!(runner_key: "claude")
        user.settings.update!(
          fallback_enabled: false,
          fallback_runners: [],
          circuit_breaker_failure_threshold: 10,
          circuit_breaker_timeout_seconds: 300
        )
        state = create_open_runner_state(user: user, runner: runner, opened_at: 10.minutes.ago)
        allow(activity).to receive(:run_agent_with_runner).and_raise(
          described_class::PreflightTimeoutError,
          "Preflight check failed: Runner smoke preflight timed out after 30s"
        )

        timed_out_run = create_runner_backed_agent_run(project: project, runner: runner)
        expect_all_runners_exhausted(activity: activity, agent_run: timed_out_run)

        state.reload
        expect(state).to be_circuit_open
        expect(state.circuit_opened_at).to be_within(5.seconds).of(Time.current)

        skipped_run = create_runner_backed_agent_run(project: project, runner: runner)

        expect(activity).not_to receive(:run_agent_with_runner)
        expect_all_runners_exhausted(activity: activity, agent_run: skipped_run)
      end

      it "calls harness preflight_check with the main execution env and timeout" do
        harness_provider = instance_double(AgentHarness::Providers::Codex)
        allow(harness_provider).to receive(:preflight_check).and_return({ healthy: true })
        allow(activity).to receive(:preflight_provider_instance).and_return(harness_provider)
        allow(activity).to receive(:run_harness_preflight!).and_call_original
        allow(activity).to receive(:command_env_for).and_wrap_original do |original, command_context, prompt|
          if prompt == "Reply with exactly OK."
            { "PROMPT_KIND" => "preflight" }
          else
            original.call(command_context, prompt).merge("PROMPT_KIND" => "main")
          end
        end
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive(:commit_uncommitted_changes).and_return(false)
        allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

        activity.execute(agent_run_id: agent_run.id)

        expect(harness_provider).to have_received(:preflight_check).with(
          env: hash_including("PROMPT_KIND" => "main"),
          timeout: described_class::PREFLIGHT_TIMEOUT_SECONDS
        )
      end

      context "when codex subscription auth is active" do
        let(:codex_provider) do
          user.runners.find_or_create_by!(runner_key: "codex").tap do |p|
            p.update!(auth_type: "subscription")
          end
        end
        let(:agent_run) do
          create(:agent_run, :with_git_context,
            project: project,
            issue: issue,
            agent_type: "codex",
            runner: codex_provider,
            container_id: "abc123")
        end

        before do
          user.runners.find_or_create_by!(runner_key: "cursor")
          user.settings.update!(fallback_enabled: true, fallback_runners: [ "cursor" ])
          allow(activity).to receive(:logger).and_return(instance_double(ActiveSupport::Logger, info: nil, warn: nil, error: nil))
          allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
          allow(activity).to receive(:run_runner_preflight!).and_call_original
          allow(activity).to receive(:run_harness_preflight!).and_call_original
        end

        it "skips harness preflight and uses smoke exec preflight instead" do
          harness_provider = instance_double(AgentHarness::Providers::Codex)
          allow(activity).to receive(:preflight_provider_instance).and_return(harness_provider)
          # If harness preflight were called, it would raise — proving the skip works.
          allow(harness_provider).to receive(:preflight_check).and_raise(
            "harness preflight should not be called for subscription auth"
          )
          allow(container_service).to receive(:execute).and_return(exec_success)
          allow(git_ops).to receive(:commit_uncommitted_changes).and_return(false)
          allow(git_ops).to receive(:has_changes_since?).with("pre_agent_sha_abc123").and_return(false)

          result = activity.execute(agent_run_id: agent_run.id)

          agent_run.reload
          expect(result).to include(success: true)
          expect(agent_run.status).to eq("running")
          expect(container_service).to have_received(:execute).at_least(:twice)
        end
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
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)
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

      it "does not enqueue ProcessRunQueueJob when another process finished the run first" do
        allow(container_service).to receive(:execute) do
          agent_run.update!(status: "completed", completed_at: Time.current)
          raise Containers::Provision::TimeoutError
        end

        expect(ProcessRunQueueJob).not_to receive(:perform_later)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError)
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
        expect(agent_run.runners_attempted.first["diagnostics"]).to include(
          "timeout_type" => "startup",
          "output_received" => false
        )
      end

      it "raises AllProvidersExhausted" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)
      end
    end

    context "when Claude hits the silent-startup heartbeat bug signature" do
      let(:heartbeat_bug_diagnostics) do
        {
          "elapsed_seconds" => 370.5,
          "output_received" => false,
          "stdout_bytes" => 0,
          "stderr_bytes" => 0,
          "heartbeat_supported" => true,
          "heartbeat_path_configured" => true,
          "heartbeat_active" => nil,
          "heartbeat_age_seconds" => nil
        }
      end

      before do
        user.runner_states.create!(runner_name: "claude", failure_count: 0, circuit_state: "closed")
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute)
          .and_raise(
            Containers::Provision::StartupTimeoutError.new(
              "No output received within 360 seconds",
              diagnostics: heartbeat_bug_diagnostics
            )
          )
      end

      it "reclassifies the run as an execution failure instead of a timeout" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("failed")
        expect(agent_run.error_message).to eq("All runners exhausted: claude_code")
        expect(agent_run.runners_attempted.first).to include(
          "runner" => "claude_code",
          "error_type" => "error"
        )
        expect(agent_run.runners_attempted.first["error_message"])
          .to include("known Claude heartbeat/MCP startup bug")
      end

      it "does not enqueue timeout queue processing for the false-positive timeout" do
        expect {
          expect {
            activity.execute(agent_run_id: agent_run.id)
          }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)
        }.not_to have_enqueued_job(ProcessRunQueueJob)
      end

      it "does not increment the Claude runner circuit for the false-positive timeout" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        claude_runner_state = user.runner_states.find_by!(runner_name: "claude")
        expect(claude_runner_state.failure_count).to eq(0)
        expect(claude_runner_state.circuit_state).to eq("closed")
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
        expect(agent_run.runners_attempted.first["diagnostics"]).to include(
          "timeout_type" => "idle",
          "effective_timeout_seconds" => 3600,
          "startup_timeout_seconds" => described_class::CREATE_PR_RUNNER_STARTUP_TIMEOUTS["claude"],
          "idle_timeout_seconds" => described_class::CREATE_PR_RUNNER_IDLE_TIMEOUTS["claude_code"],
          "heartbeat_supported" => true
        )
      end

      it "raises AllProvidersExhausted" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)
      end
    end

    context "when a timeout invalidates the container before fallback" do
      before do
        user.runners.find_or_create_by!(runner_key: "cursor")
        user.settings.update!(fallback_enabled: true, fallback_runners: [ "cursor" ])
        allow(git_ops).to receive_messages(
          head_sha: "pre_agent_sha_abc123",
          commit_uncommitted_changes: false,
          has_changes_since?: false
        )
        execute_calls = 0
        allow(container_service).to receive(:execute) do
          execute_calls += 1
          if execute_calls == 1
            AgentRun.where(id: agent_run.id).update_all(container_id: nil)
            raise Containers::Provision::TimeoutError.new(
              "execution timed out",
              diagnostics: { "elapsed_seconds" => 901.2, "output_received" => true, "heartbeat_active" => false }
            )
          else
            exec_success
          end
        end
        allow(agent_run).to receive(:provision_container) { agent_run.update!(container_id: "reprovisioned-123") }
        allow(Containers::Provision).to receive(:reconnect) do |agent_run:, container_id:|
          raise "unexpected container id #{container_id}" unless [ "abc123", "reprovisioned-123" ].include?(container_id)

          container_service
        end
      end

      it "reprovisions the container and continues with the fallback runner" do
        result = activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(result).to include(success: true, final_runner: "cursor")
        expect_timeout_fallback_recovery(agent_run)
      end
    end

    context "when a timeout leaves a stale container id before fallback" do
      before do
        user.runners.find_or_create_by!(runner_key: "cursor")
        user.settings.update!(fallback_enabled: true, fallback_runners: [ "cursor" ])
        allow(git_ops).to receive_messages(
          head_sha: "pre_agent_sha_abc123",
          commit_uncommitted_changes: false,
          has_changes_since?: false
        )

        execute_calls = 0
        allow(container_service).to receive(:execute) do
          execute_calls += 1
          if execute_calls == 1
            raise Containers::Provision::TimeoutError.new(
              "execution timed out",
              diagnostics: { "elapsed_seconds" => 901.2, "output_received" => true, "heartbeat_active" => false }
            )
          else
            exec_success
          end
        end

        allow(agent_run).to receive(:provision_container) { agent_run.update!(container_id: "reprovisioned-123") }

        reconnect_calls = 0
        allow(Containers::Provision).to receive(:reconnect) do |agent_run:, container_id:|
          reconnect_calls += 1
          if reconnect_calls == 2
            raise wrap_error(
              Containers::Provision::ProvisionError.new("Container #{container_id} not found")
            )
          end

          raise "unexpected container id #{container_id}" unless [ "abc123", "reprovisioned-123" ].include?(container_id)

          container_service
        end
      end

      it "reprovisions the container and continues with the fallback runner" do
        result = activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(result).to include(success: true, final_runner: "cursor")
        expect_timeout_fallback_recovery(agent_run)
      end
    end

    context "when fallback recovery cannot reprovision the container" do
      before do
        user.runners.find_or_create_by!(runner_key: "cursor")
        user.settings.update!(fallback_enabled: true, fallback_runners: [ "cursor" ])
        allow(git_ops).to receive_messages(
          head_sha: "pre_agent_sha_abc123",
          commit_uncommitted_changes: false,
          has_changes_since?: false
        )
        allow(container_service).to receive(:execute) do
          AgentRun.where(id: agent_run.id).update_all(container_id: nil)
          raise Containers::Provision::TimeoutError.new(
            "execution timed out",
            diagnostics: { "elapsed_seconds" => 901.2, "output_received" => true, "heartbeat_active" => false }
          )
        end
        allow(agent_run).to receive(:provision_container).and_raise(Containers::Provision::ProvisionError, "docker unavailable")
      end

      it "preserves the timeout instead of failing the fallback with no container" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("wall_clock_timeout")
        expect(agent_run.error_message).not_to include("No container provisioned")
        expect(agent_run.runners_attempted).to contain_exactly(
          hash_including("runner" => "claude_code", "success" => false, "error_type" => "timeout")
        )
      end
    end

    context "when a timeout is followed by a transient reconnect failure during fallback availability checks" do
      before do
        user.runners.find_or_create_by!(runner_key: "cursor")
        user.settings.update!(fallback_enabled: true, fallback_runners: [ "cursor" ])
        allow(git_ops).to receive_messages(
          head_sha: "pre_agent_sha_abc123",
          commit_uncommitted_changes: false,
          has_changes_since?: false
        )

        execute_calls = 0
        allow(container_service).to receive(:execute) do
          execute_calls += 1
          if execute_calls == 1
            raise Containers::Provision::TimeoutError, "execution timed out"
          else
            exec_success
          end
        end

        reconnect_calls = 0
        allow(Containers::Provision).to receive(:reconnect) do
          reconnect_calls += 1
          if reconnect_calls == 2
            raise wrap_error(
              Containers::Provision::ProvisionError.new("Failed to reconnect to container: connection reset")
            )
          end

          container_service
        end
      end

      it "still attempts fallback and succeeds" do
        result = activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(result).to include(success: true, final_runner: "cursor")
        expect(agent_run.runners_attempted).to contain_exactly(
          hash_including("runner" => "claude_code", "success" => false, "error_type" => "timeout"),
          hash_including("runner" => "cursor", "success" => true)
        )
        expect(agent_run.runner_switches).to eq(1)
      end
    end

    context "when primary preflight times out at mid and a direct-outbound fallback succeeds with its native mid model" do
      let(:opencode_runner) do
        api_key = create(:runner_api_key, user: user, api_service_type: "openrouter")
        create_opencode_runner_entry(
          user: user, api_key: api_key,
          name: "Kimi K2", model: "moonshotai/kimi-k2-0905"
        )
      end

      before do
        llm_model = create(:llm_model, model_id: "claude-sonnet-4-6", provider: "anthropic", tier: "mid")
        create(:model_selection, agent_run: agent_run, llm_model: llm_model, tier: "mid")

        allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude opencode])

        user.settings.update!(
          fallback_enabled: true,
          fallback_runners: [ opencode_runner.routing_key ]
        )

        allow(git_ops).to receive_messages(
          head_sha: "pre_agent_sha_abc123",
          commit_uncommitted_changes: false,
          has_changes_since?: false
        )

        allow(activity).to receive(:run_runner_preflight!).and_call_original
        allow(activity).to receive(:run_harness_preflight!)
      end

      it "falls back to the direct-outbound runner and records per-attempt resolved ids" do
        call_count = 0
        execute_calls = []
        allow(container_service).to receive(:execute) do |command, **opts|
          call_count += 1
          execute_calls << [ command, opts ]

          call_count == 1 ? raise(Containers::Provision::TimeoutError, "execution timed out") : exec_success
        end

        result = activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(result).to include(success: true)
        expect(result[:final_runner]).to eq(opencode_runner.routing_key)
        expect_opencode_runtime_execute_calls(execute_calls)
        expect_resolved_model_attempts(agent_run, opencode_runner)
        expect(agent_run.runner_switches).to eq(1)
      end
    end

    context "when no configured runner supports the requested tier" do
      before do
        llm_model = create(:llm_model, model_id: "claude-opus-4-1", provider: "anthropic", tier: "high")
        create(:model_selection, agent_run: agent_run, llm_model: llm_model, tier: "high")

        allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[opencode])
      end

      it "fast-fails with NoTierCapableRunner before any attempt executes" do
        primary_runner = create_low_only_opencode_runner(user: user, name: "Primary Kimi")
        fallback_runner = create_low_only_opencode_runner(user: user, name: "Fallback Kimi")
        agent_run.update!(runner: primary_runner)
        user.settings.update!(fallback_enabled: true, fallback_runners: [ fallback_runner.routing_key ])

        expect(container_service).not_to receive(:execute)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /No runner supports tier high/)

        agent_run.reload
        expect(agent_run.status).to eq("failed")
        expect(agent_run.error_message).to eq("No runner supports tier high")
        expect(agent_run.runners_attempted).to eq([])
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

      it "wraps ContainerNotProvisioned as RunnerExecutionError when a prior runner attempt is already recorded" do
        other_issue = create(:issue, project: project)
        prior_attempt = {
          "runner" => "claude_code",
          "success" => false,
          "error_type" => "error",
          "error_message" => "prior runner failure (real root cause)"
        }
        run_no_container = create(
          :agent_run, :with_git_context,
          project: project,
          issue: other_issue,
          container_id: nil,
          runners_attempted: [ prior_attempt ]
        )
        allow(AgentRun).to receive(:find).with(run_no_container.id).and_return(run_no_container)

        expect {
          activity.execute(agent_run_id: run_no_container.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        # The prior failure remains the first entry so the real root cause is preserved
        # even though the run now surfaces AllRunnersExhausted at the activity boundary.
        expect(run_no_container.reload.runners_attempted.first)
          .to include("error_message" => "prior runner failure (real root cause)")
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

    it "raises UntrustedIssue when prompt building rejects an untrusted issue" do
      allow(agent_run).to receive(:effective_prompt)
        .and_raise(Prompts::BuildForIssue::UntrustedIssueError, "Issue #1 creator 'attacker' is not trusted")

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.message).to include("Issue #1 creator 'attacker' is not trusted")
        expect(error.type).to eq("UntrustedIssue")
      }
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
      }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)
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
            idle_timeout: described_class::DEFAULT_ISSUE_GOAL_IDLE_TIMEOUT
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

    context "when goal is analyze_issue" do
      let(:agent_run) do
        create(:agent_run, :analyze_issue_goal, project: project, issue: issue, container_id: "abc123")
      end

      before do
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive(:head_sha).and_return("sha123")
      end

      it "uses the shorter issue goal timeout" do
        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(timeout: described_class::DEFAULT_ISSUE_GOAL_TIMEOUT)
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end
    end

    context "when goal is create_pr" do
      it "uses runner-specific idle timeout (claude_code) on first attempt" do
        project.update!(max_execution_seconds: 86_400)
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(
            timeout: AGENT_TIMEOUT_DEFAULT,
            startup_timeout: described_class::CREATE_PR_RUNNER_STARTUP_TIMEOUTS["claude"],
            idle_timeout: described_class::CREATE_PR_RUNNER_IDLE_TIMEOUTS["claude_code"]
          )
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "caps startup timeout by the remaining execution budget" do
        agent_run.update!(status: "running", started_at: 4.minutes.ago)
        project.update!(max_execution_seconds: 270)
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(
            timeout: 30,
            startup_timeout: 30
          )
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "does not apply idle timeout to runners without heartbeat support" do
        agent_run.update!(agent_type: "gemini")
        project.update!(max_execution_seconds: 86_400)
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(
            timeout: AGENT_TIMEOUT_DEFAULT,
            startup_timeout: described_class::DEFAULT_AGENT_STARTUP_TIMEOUT,
            idle_timeout: nil,
            heartbeat_path: nil
          )
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "applies runner-specific idle timeout to kilocode via upstream harness" do
        agent_run.update!(agent_type: "kilocode")
        project.update!(max_execution_seconds: 86_400)
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(
            timeout: AGENT_TIMEOUT_DEFAULT,
            startup_timeout: described_class::CREATE_PR_RUNNER_STARTUP_TIMEOUTS["kilocode"],
            idle_timeout: described_class::CREATE_PR_RUNNER_IDLE_TIMEOUTS["kilocode"],
            heartbeat_path: "/tmp/paid-heartbeat-test/.paid-heartbeat"
          )
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "applies runner-specific idle timeout to opencode via upstream harness" do
        agent_run.update!(agent_type: "opencode")
        project.update!(max_execution_seconds: 86_400)
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(
            timeout: AGENT_TIMEOUT_DEFAULT,
            startup_timeout: described_class::CREATE_PR_RUNNER_STARTUP_TIMEOUTS["opencode"],
            idle_timeout: described_class::CREATE_PR_RUNNER_IDLE_TIMEOUTS["opencode"],
            heartbeat_path: "/tmp/paid-heartbeat-test/.paid-heartbeat"
          )
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "applies extended idle timeout to codex using per-runner constant with coarse heartbeat multiplier" do
        agent_run.update!(agent_type: "codex")
        project.update!(max_execution_seconds: 86_400)
        allow(activity).to receive(:run_harness_preflight!)
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        expected_idle = described_class::CREATE_PR_RUNNER_IDLE_TIMEOUTS["codex"] * Containers::HeartbeatSetup::COARSE_HEARTBEAT_IDLE_TIMEOUT_MULTIPLIER

        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(
            timeout: AGENT_TIMEOUT_DEFAULT,
            startup_timeout: described_class::CREATE_PR_RUNNER_STARTUP_TIMEOUTS["codex"],
            idle_timeout: expected_idle,
            heartbeat_path: "/tmp/paid-heartbeat-test/.paid-heartbeat"
          )
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "uses explicit user idle timeout when customized to a non-legacy value" do
        agent_run.update!(agent_type: "codex")
        project.update!(max_execution_seconds: 86_400)
        user.settings.update!(create_pr_idle_timeout_seconds: 420)
        allow(activity).to receive(:run_harness_preflight!)
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        expected_idle = 420 * Containers::HeartbeatSetup::COARSE_HEARTBEAT_IDLE_TIMEOUT_MULTIPLIER

        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(
            timeout: AGENT_TIMEOUT_DEFAULT,
            startup_timeout: described_class::CREATE_PR_RUNNER_STARTUP_TIMEOUTS["codex"],
            idle_timeout: expected_idle
          )
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "honours explicit user idle timeout on subsequent attempts without applying the retry multiplier" do
        agent_run.update!(agent_type: "codex")
        project.update!(max_execution_seconds: 86_400)
        user.settings.update!(create_pr_idle_timeout_seconds: 420)
        agent_run.record_runner_attempt("codex", success: false, error_type: "error")
        allow(activity).to receive(:run_harness_preflight!)
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        # Explicit user value (420) must be used verbatim — the retry multiplier
        # only escalates the per-runner tuned default, not explicit user
        # customizations.
        expected_idle = 420 * Containers::HeartbeatSetup::COARSE_HEARTBEAT_IDLE_TIMEOUT_MULTIPLIER

        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(
            timeout: AGENT_TIMEOUT_DEFAULT,
            startup_timeout: described_class::CREATE_PR_RUNNER_STARTUP_TIMEOUTS["codex"],
            idle_timeout: expected_idle
          )
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "applies the retry idle timeout multiplier on subsequent runner attempts" do
        project.update!(max_execution_seconds: 86_400)
        agent_run.record_runner_attempt("claude_code", success: false, error_type: "error")
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        expected_idle = (described_class::CREATE_PR_RUNNER_IDLE_TIMEOUTS["claude_code"] *
          described_class::RETRY_IDLE_TIMEOUT_MULTIPLIER).ceil

        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(
            timeout: AGENT_TIMEOUT_DEFAULT,
            startup_timeout: described_class::CREATE_PR_RUNNER_STARTUP_TIMEOUTS["claude_code"],
            idle_timeout: expected_idle
          )
        ).and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "falls back to the container heartbeat path for volume-backed workspaces" do
        agent_run.update!(worktree_path: nil)
        project.update!(max_execution_seconds: 86_400)
        allow(container_service).to receive_messages(execute: exec_success, heartbeat_host_path: nil)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        expect(container_service).to receive(:execute).with(
          anything,
          hash_including(
            timeout: AGENT_TIMEOUT_DEFAULT,
            startup_timeout: described_class::CREATE_PR_RUNNER_STARTUP_TIMEOUTS["claude"],
            idle_timeout: described_class::CREATE_PR_RUNNER_IDLE_TIMEOUTS["claude_code"],
            heartbeat_path: Containers::HeartbeatSetup::CONTAINER_HEARTBEAT_PATH
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
        allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor aider])
        user.runners.find_or_create_by!(runner_key: "cursor")
        user.runners.find_or_create_by!(runner_key: "aider")
        user.settings.update!(fallback_enabled: true, fallback_runners: %w[claude cursor aider])
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)
      end

      it "falls back to next runner on rate limit" do
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
        expect(result[:final_runner]).to eq("cursor")
      end

      it "falls back to the next runner on docker exec failures" do
        call_count = 0
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          call_count += 1
          if call_count == 1
            raise Containers::Provision::ExecutionError, "Connection reset by peer"
          end

          exec_success
        end

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
        expect(result[:final_runner]).to eq("cursor")
        expect(agent_run.reload.runners_attempted).to contain_exactly(
          hash_including("runner" => "claude_code", "success" => false, "error_type" => "error",
            "error_message" => include("Docker exec error")),
          hash_including("runner" => "cursor", "success" => true)
        )
      end

      it "includes configured fallback-only runners even when saved fallback order is empty" do
        user.runners.find_by!(runner_key: "cursor").update!(
          enabled_for_agent_runs: false,
          enabled_for_fallback: true
        )
        user.settings.update!(fallback_enabled: true, fallback_runners: [])

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
        expect(result[:final_runner]).to eq("aider")
      end

      it "records runner switch when falling back" do
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

        expect(agent_run.reload.runner_switches).to eq(1)
      end

      # Regression test for the hook-staleness-on-fallback bug
      # (#1163 comment thread): the commit-msg hook is seeded at clone time
      # with the initial runner's trailer. If the agent's first runner
      # hits a rate limit and falls back, intermediate commits made by the
      # fallback runner's agent must carry the *fallback* runner's
      # trailer — not the initial one. Refreshing the trailer file on each
      # runner attempt is how that guarantee is kept.
      it "refreshes the co-author trailer file for each runner attempt so fallback commits get the new trailer" do
        claude = user.runners.find_by!(runner_key: "claude", auth_type: "subscription")
        cursor = user.runners.find_by!(runner_key: "cursor")
        claude.update!(agent_co_author_trailer: "Co-Authored-By: Claude <noreply@anthropic.com>")
        cursor.update!(agent_co_author_trailer: "Co-Authored-By: Cursor <ai@cursor.com>")

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

        # Two runner attempts → two trailer refreshes, in order.
        expect(git_ops).to have_received(:write_co_author_trailer).with(claude).ordered
        expect(git_ops).to have_received(:write_co_author_trailer).with(cursor).ordered
      end

      it "does not refresh the co-author trailer file when the run has no git repo" do
        create_issue_run = create(:agent_run, :create_issue_goal, :with_git_context,
          project: project, issue: issue, container_id: "abc123")
        allow(AgentRun).to receive(:find).with(create_issue_run.id).and_return(create_issue_run)
        allow(Containers::Provision).to receive(:reconnect)
          .with(agent_run: create_issue_run, container_id: "abc123")
          .and_return(container_service)
        allow(Containers::GitOperations).to receive(:new)
          .with(container_service: container_service, agent_run: create_issue_run)
          .and_return(git_ops)

        allow(container_service).to receive(:execute).and_return(exec_success)

        activity.execute(agent_run_id: create_issue_run.id)

        expect(git_ops).not_to have_received(:write_co_author_trailer)
      end

      it "continues to the next runner when the first runner times out" do
        allow(container_service).to receive(:execute)
          .and_raise(Containers::Provision::TimeoutError, "took too long")

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)
          .and have_enqueued_job(ProcessRunQueueJob)

        agent_run.reload

        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("wall_clock_timeout")
        expect(agent_run.runners_attempted.map { |attempt| attempt["runner"] }).to eq(
          %w[claude_code cursor aider]
        )
        expect(agent_run.final_runner).to be_nil
      end

      it "reclassifies timeout output that contains quota errors as rate limited" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stderr", "Error: Free tier limit reached. Please upgrade to a paid plan to continue using the service.")
          3.times { |index| agent_run.log!("stdout", "still waiting on runner chunk #{index}") }
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.runners_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "reclassifies timeout output as rate limited when quota message is within the log scan window" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stderr", "Free tier limit reached. Please upgrade for higher usage.")
          100.times { |index| agent_run.log!("stdout", "runner still warming up: #{index}") }
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.runners_attempted.first["error_type"]).to eq("rate_limited")
      end

      def insert_bounded_timeout_logs(agent_run)
        now = Time.current
        rows = [ {
          agent_run_id: agent_run.id,
          log_type: "stderr",
          content: "Free tier limit reached. Please upgrade for higher usage.",
          created_at: now - 5.minutes
        } ]
        rows.concat(Array.new(201) do |index|
          {
            agent_run_id: agent_run.id,
            log_type: "stdout",
            content: "runner still warming up: #{index}",
            created_at: now - index.seconds
          }
        end)
        AgentRunLog.insert_all!(rows)
      end

      it "does not reclassify timeout when quota message falls outside the bounded log scan window" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          insert_bounded_timeout_logs(agent_run)
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)
          .and have_enqueued_job(ProcessRunQueueJob)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.runners_attempted.first["error_type"]).to eq("timeout")
      end

      it "reclassifies timeout output as rate limited when the quota signal spans chunk boundaries" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stderr", "Free tier")
          agent_run.log!("stderr", " limit reached while processing request")
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.runners_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "reclassifies timeout output as rate limited when HTTP 429 appears in output" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stderr", "Error: HTTP 429 Too Many Requests")
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.runners_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "reclassifies timeout output as rate limited when 'too many requests' appears with 429 context" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stderr", "Error 429: Too many requests. Please retry after 60 seconds.")
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.runners_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "does not reclassify timeouts when recent output only mentions rate limits conversationally" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stdout", "Document how to handle a service overloaded response and a server at capacity banner in the retry guide.")
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)
          .and have_enqueued_job(ProcessRunQueueJob)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("idle_timeout")
        expect(agent_run.runners_attempted.first["error_type"]).to eq("timeout")
      end

      it "does not reclassify timeouts when 'too many requests' appears without 429 context" do
        allow(container_service).to receive(:execute) do |_cmd, **_opts|
          agent_run.log!("stdout", "You have sent too many requests in a given amount of time.")
          raise Containers::Provision::IdleTimeoutError, "No output received for 300 seconds"
        end

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)
          .and have_enqueued_job(ProcessRunQueueJob)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("idle_timeout")
        expect(agent_run.runners_attempted.first["error_type"]).to eq("timeout")
      end

      it "classifies OutputAbortError from quota patterns as rate_limited instead of timeout" do
        allow(container_service).to receive(:execute).and_raise(
          Containers::Provision::OutputAbortError.new(
            "Process aborted: fatal output pattern detected",
            matched_output: "Error: Free tier limit reached. Please upgrade to a paid plan."
          )
        )

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.runners_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "detects a real quota error returned with exit code 0 and marks the runner rate-limited" do
        quota_success = Containers::Provision::Result.success(
          stdout: "Error: Your billing limit has been reached. Please add credits.", stderr: "", exit_code: 0
        )
        allow(container_service).to receive(:execute).and_return(quota_success)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.runners_attempted.first["error_type"]).to eq("rate_limited")
        expect(agent_run.runners_attempted.first["error_message"]).to include("credit/quota exhausted")
        runner_state = user.runner_states.find_by(runner_name: "claude")
        expect(runner_state&.rate_limited_until).to be_within(2.minutes).of(
          described_class::INSUFFICIENT_CREDITS_BACKOFF.from_now
        )
      end

      it "does not misclassify substantial agent output as a quota error when pattern appears in test descriptions" do
        long_stdout = (1..40).map { |i| "includes test case number #{i} for the billing and rate limit patterns" }.join("\n")
        long_output_success = Containers::Provision::Result.success(
          stdout: long_stdout, stderr: "", exit_code: 0
        )
        allow(container_service).to receive(:execute).and_return(long_output_success)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
      end

      it "detects a short standalone rate limit error returned with exit code 0" do
        rate_limit_success = Containers::Provision::Result.success(
          stdout: "Free model usage limit reached. Please try again later.", stderr: "", exit_code: 0
        )
        allow(container_service).to receive(:execute).and_return(rate_limit_success)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.runners_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "detects a weekly limit error returned with exit code 0" do
        rate_limit_success = Containers::Provision::Result.success(
          stdout: "Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-05-18 11:22:32", stderr: "", exit_code: 0
        )
        allow(container_service).to receive(:execute).and_return(rate_limit_success)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.runners_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "detects a short rate limit line wrapped in otherwise successful output" do
        rate_limit_success = Containers::Provision::Result.success(
          stdout: "OK.\nWeekly/Monthly Limit Exhausted. Your limit will reset at 2026-05-18 11:22:32",
          stderr: "",
          exit_code: 0
        )
        allow(container_service).to receive(:execute).and_return(rate_limit_success)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.runners_attempted.first["error_type"]).to eq("rate_limited")
      end

      it "detects ProviderModelNotFoundError returned with exit code 0" do
        model_not_found_stderr = <<~ERR
          Error: Model not found: glm-5.1/.
          ProviderModelNotFoundError
           data: {
            providerID: "glm-5.1",
            modelID: "",
            suggestions: [],
          }
        ERR
        model_not_found_success = Containers::Provision::Result.success(
          stdout: "", stderr: model_not_found_stderr, exit_code: 0
        )
        allow(container_service).to receive(:execute).and_return(model_not_found_success)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("failed")
        expect(agent_run.runners_attempted.first["error_type"]).to eq("error")
        expect(agent_run.runners_attempted.first["error_message"]).to include("model not found error")
      end

      it "detects ProviderModelNotFoundError even when stderr includes a long stack trace" do
        stack_trace = Array.new(60) { |i| "    at resolveModel (file:///app/.opencode/vendor/index.js:#{200 + i}:17)" }.join("\n")
        model_not_found_stderr = <<~ERR
          Error: Model not found: glm-5.1/.
          ProviderModelNotFoundError
          #{stack_trace}
        ERR
        model_not_found_success = Containers::Provision::Result.success(
          stdout: "", stderr: model_not_found_stderr, exit_code: 0
        )
        allow(container_service).to receive(:execute).and_return(model_not_found_success)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("failed")
        expect(agent_run.runners_attempted.first["error_type"]).to eq("error")
        expect(agent_run.runners_attempted.first["error_message"]).to include("model not found error")
      end

      it "does not misclassify substantial agent output as model not found when ProviderModelNotFoundError appears in structured output" do
        long_stdout = (1..40).map { |i| "line #{i}: processing test for ProviderModelNotFoundError handling" }.join("\n")
        long_output_success = Containers::Provision::Result.success(
          stdout: long_stdout, stderr: "", exit_code: 0
        )
        allow(container_service).to receive(:execute).and_return(long_output_success)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
      end

      it "preserves timeout handling when the timeout happens before runner execution starts" do
        allow(activity).to receive(:augment_prompt_for_goal)
          .and_raise(Containers::Provision::TimeoutError, "took too long before exec")

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)
          .and have_enqueued_job(ProcessRunQueueJob)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("wall_clock_timeout")
      end

      it "raises AllProvidersExhausted when all fallbacks fail" do
        allow(container_service).to receive(:execute).and_return(exec_failure)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)
      end

      it "marks run as rate_limited when all runners hit rate limits" do
        allow(container_service).to receive(:execute).and_return(rate_limit_failure)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
      end

      it "surfaces a single compatible attempted runner as rate limited" do
        kimi_runner = configure_single_compatible_opencode_runner(agent_run: agent_run, user: user)

        allow(container_service).to receive(:execute).and_return(rate_limit_failure)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(
          Temporalio::Error::ApplicationError,
          /No compatible runner available: .* is the only runner compatible with moonshotai\/kimi-k2-0905 and it is currently rate limited/
        )

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to match(
          /No compatible runner available: .* is the only runner compatible with moonshotai\/kimi-k2-0905 and it is currently rate limited/
        )
        expect(agent_run.runners_attempted.map { |attempt| attempt["runner"] }).to eq([ kimi_runner.routing_key ])
      end

      it "classifies 'exhausted ... capacity' as a rate limit" do
        gemini_rate_limit = Containers::Provision::Result.failure(
          error: "exit 1", stdout: "", stderr: "You have exhausted your capacity on this model.", exit_code: 1
        )
        allow(container_service).to receive(:execute).and_return(gemini_rate_limit)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.rate_limited_until).to be_present
      end

      it "classifies kilocode glm free model usage limit wording as a rate limit" do
        glm_rate_limit = Containers::Provision::Result.failure(
          error: "exit 1", stdout: "", stderr: "Free model usage limit reached. Please try again later.", exit_code: 1
        )
        allow(container_service).to receive(:execute).and_return(glm_rate_limit)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.rate_limited_until).to be_present
      end

      it "classifies weekly limit wording as a rate limit" do
        weekly_rate_limit = Containers::Provision::Result.failure(
          error: "exit 1", stdout: "", stderr: "Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-05-18 11:22:32", exit_code: 1
        )
        allow(container_service).to receive(:execute).and_return(weekly_rate_limit)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

        agent_run.reload
        expect(agent_run.status).to eq("rate_limited")
        expect(agent_run.error_message).to include("rate limited")
        expect(agent_run.rate_limited_until).to be_present
      end

      it "executes a rate-limit fallback entry for the same runner key" do
        fallback_provider = create_claude_rate_limit_fallback_provider

        expect_same_provider_rate_limit_fallback_execution(fallback_provider)
      end

      it "executes a rate-limit fallback entry even when enabled_for_agent_runs is false" do
        fallback_provider = create_claude_rate_limit_fallback_provider
        fallback_provider.update!(enabled_for_agent_runs: false)

        expect_same_provider_rate_limit_fallback_execution(fallback_provider)
      end

      it "skips a rate-limit fallback entry whose RunnerState is already rate limited" do
        fallback_provider = create_claude_rate_limit_fallback_provider
        fallback_provider.user.runner_states.find_or_create_by!(runner_name: fallback_provider.routing_key).update!(
          rate_limited_until: 2.hours.from_now
        )
        user.settings.update!(fallback_enabled: true, fallback_runners: [ "claude" ])
        execute_calls = []

        allow(container_service).to receive(:execute) do |command, **opts|
          execute_calls << [ command, opts ]
          execute_calls.one? ? rate_limit_failure : exec_success
        end

        result = activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(result[:success]).to be true
        expect(agent_run.runners_attempted).to include(
          include("runner" => "claude_code", "error_type" => "rate_limited"),
          include("runner" => fallback_provider.routing_key, "error_type" => "rate_limited")
        )
        expect(execute_calls.any? { |_command, opts| opts[:env].value?("sk-fallback-secret") }).to be(false)
      end

      it "uses runner display names in exhausted-runner labels" do
        api_key = create(:runner_api_key, user: user, api_service_type: "openrouter")
        kimi = create_opencode_runner_entry(user: user, api_key: api_key, name: "Kimi K2.5", model: "moonshotai/kimi-k2-0905")
        opus = create_opencode_runner_entry(user: user, api_key: api_key, name: "Opus via OpenCode", model: "anthropic/claude-opus-4.1")

        labels = activity.send(:runner_attempt_labels, [ kimi.routing_key, opus.routing_key ], agent_run, user)

        expect(labels).to eq([ "Kimi K2.5", "Opus via OpenCode" ])
      end

      it "executes routing-key fallbacks with the runner entry config intact" do
        allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor aider opencode])
        api_key = create(:runner_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret")
        opencode_runner = create_opencode_runner_entry(
          user: user,
          api_key: api_key,
          name: "Kimi K2.5",
          model: "moonshotai/kimi-k2-0905"
        )
        user.settings.update!(fallback_enabled: true, fallback_runners: [ opencode_runner.routing_key ])

        expect_opencode_fallback_execution(opencode_runner)
      end

      it "marks run as rate_limited when all runners are already rate limited in ProviderState" do
        reset_time = 2.hours.from_now

        # Pre-set all runner states as rate limited so runner_unavailable? skips them
        %w[claude cursor aider].each do |provider_name|
          user.runner_states.find_or_create_by!(runner_name: provider_name).tap do |state|
            state.update!(rate_limited_until: reset_time)
          end
        end

        # No container execution should occur since all runners are skipped
        expect(container_service).not_to receive(:execute)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)

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
        }.to raise_error(Temporalio::Error::ApplicationError, /All runners exhausted/)
          .and have_enqueued_job(ProcessRunQueueJob)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("wall_clock_timeout")
      end

      it "caps fallback attempts to the remaining project time budget" do
        freeze_time do
          agent_run.update!(status: "running", started_at: 10.seconds.ago)
          project.update!(max_execution_seconds: 90)

          call_count = 0
          expect(container_service).to receive(:execute).twice do |_cmd, **opts|
            call_count += 1
            if call_count == 1
              expect(opts[:timeout]).to eq(80)
              agent_run.update!(started_at: 89.seconds.ago)
              exec_failure
            else
              expect(opts[:timeout]).to eq(1)
              exec_success
            end
          end

          result = activity.execute(agent_run_id: agent_run.id)

          expect(result[:success]).to be true
          expect(result[:final_runner]).to eq("cursor")
        end
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

    it "times out when execution time limit is exceeded" do
      project.update!(max_execution_seconds: 60)
      agent_run.update!(started_at: 2.minutes.ago, status: "running")

      allow(AgentRuns::Cancel).to receive(:call)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(
        Temporalio::Error::ApplicationError,
        "All runners exhausted"
      )

      agent_run.reload
      expect(agent_run.status).to eq("timeout")
      expect(agent_run.guardrail_violation_type).to eq("time_limit")
      expect(AgentRuns::Cancel).to have_received(:call).with(agent_run: agent_run, skip_status_update: true)
    end

    it "preserves a terminal result when another guardrail already timed out the run" do
      project.update!(max_execution_seconds: 60)
      agent_run.update!(started_at: 2.minutes.ago, status: "running")

      violation_result = instance_double(Guardrails::ViolationHandler::Result, paused?: false)
      allow(Guardrails::ViolationHandler).to receive(:call) do
        agent_run.update!(status: "timeout", completed_at: Time.current, guardrail_violation_type: "cost_limit")
        violation_result
      end

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(
        Temporalio::Error::ApplicationError,
        "All runners exhausted"
      )

      agent_run.reload
      expect(agent_run.status).to eq("timeout")
      expect(agent_run.guardrail_violation_type).to eq("cost_limit")
    end
  end

  describe "user-configurable max_execution_seconds" do
    before do
      allow(container_service).to receive(:execute).and_return(exec_success)
      allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)
    end

    it "uses user setting max_execution_seconds when set" do
      project.update!(max_execution_seconds: 3600)
      user.settings.update!(max_execution_seconds: 600)
      agent_run.update!(started_at: 5.minutes.ago, status: "running")

      expect(container_service).to receive(:execute).with(
        anything,
        hash_including(timeout: a_value <= 300)
      ).and_return(exec_success)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "falls back to project setting when user setting is nil" do
      project.update!(max_execution_seconds: 600)
      user.settings.update!(max_execution_seconds: nil)
      agent_run.update!(started_at: 5.minutes.ago, status: "running")

      expect(container_service).to receive(:execute).with(
        anything,
        hash_including(timeout: a_value <= 300)
      ).and_return(exec_success)

      activity.execute(agent_run_id: agent_run.id)
    end
  end

  describe "loop guardrail handling" do
    before do
      allow(container_service).to receive(:execute).and_return(exec_success)
      allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)
    end

    it "does not overwrite a terminal guardrail result raised during loop handling" do
      allow(activity).to receive(:run_agent_with_runner).and_raise(described_class::InfiniteLoopError, "loop detected")

      violation_result = instance_double(Guardrails::ViolationHandler::Result, paused?: false)
      allow(Guardrails::ViolationHandler).to receive(:call) do
        agent_run.update!(status: "timeout", completed_at: Time.current, guardrail_violation_type: "cost_limit")
        violation_result
      end

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(
        Temporalio::Error::ApplicationError,
        "Infinite loop detected: loop detected"
      )

      agent_run.reload
      expect(agent_run.status).to eq("timeout")
      expect(agent_run.guardrail_violation_type).to eq("cost_limit")
    end
  end

  describe "#rate_limit_reset_at" do
    let(:harness_provider) { double(parse_rate_limit_reset: 1.hour.ago) }

    before do
      allow(RunnerSupport).to receive(:runner_key_for_agent_type).with("claude_code").and_return("claude")
      allow(RunnerSupport).to receive(:harness_runner_key_for).with("claude").and_return("claude")
      allow(AgentHarness).to receive(:provider).with(:claude).and_return(harness_provider)
    end

    it "falls back when agent-harness parses a stale reset time" do
      freeze_time do
        reset_at = activity.send(:rate_limit_reset_at, "claude_code", "Rate limit exceeded. Reset at: 1")

        expect(reset_at).to eq(1.hour.from_now)
      end
    end
  end

  describe "terminal guardrail preservation after runner exhaustion" do
    before do
      allow(container_service).to receive(:execute).and_return(exec_failure)
      allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)
    end

    it "preserves terminal guardrail state when a guardrail times out the run during runner execution" do
      # Simulate a cost budget guardrail timing out the run during execution
      allow(container_service).to receive(:execute) do
        agent_run.update!(status: "timeout", completed_at: Time.current, guardrail_violation_type: "cost_limit")
        exec_failure
      end

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(
        Temporalio::Error::ApplicationError,
        "All runners exhausted"
      )

      agent_run.reload
      expect(agent_run.status).to eq("timeout")
      expect(agent_run.guardrail_violation_type).to eq("cost_limit")
    end
  end

  describe "MCP-enabled execution" do
    describe "#effective_mcp_servers_for" do
      it "returns empty array when no MCP servers are provisioned" do
        result = activity.send(:effective_mcp_servers_for, agent_run)
        expect(result).to eq([])
      end

      it "assembles stdio servers from provisioned state" do
        agent_run.update_columns(mcp_provisioned_servers: {
          "stdio_servers" => [ { "name" => "fs", "transport" => "stdio", "command" => "npx-pkg", "args" => [ "/ws" ] } ],
          "url_servers" => []
        })

        result = activity.send(:effective_mcp_servers_for, agent_run)

        expect(result).to contain_exactly(
          { name: "fs", transport: "stdio", command: "npx-pkg", args: [ "/ws" ] }
        )
      end

      it "assembles url servers from provisioned state" do
        agent_run.update_columns(mcp_provisioned_servers: {
          "stdio_servers" => [],
          "url_servers" => [ { "name" => "pw", "transport" => "sse", "url" => "http://host:3000/sse" } ]
        })

        result = activity.send(:effective_mcp_servers_for, agent_run)

        expect(result).to contain_exactly(
          { name: "pw", transport: "sse", url: "http://host:3000/sse" }
        )
      end

      it "combines both stdio and url servers" do
        agent_run.update_columns(mcp_provisioned_servers: {
          "stdio_servers" => [ { "name" => "fs", "transport" => "stdio", "command" => "npx-pkg" } ],
          "url_servers" => [ { "name" => "pw", "transport" => "sse", "url" => "http://host:3000/sse" } ]
        })

        result = activity.send(:effective_mcp_servers_for, agent_run)

        expect(result.size).to eq(2)
        expect(result.map { |s| s[:name] }).to contain_exactly("fs", "pw")
      end
    end

    describe "#validate_provider_mcp_support!" do
      it "does nothing when mcp_servers is empty" do
        expect {
          activity.send(:validate_provider_mcp_support!, "claude_code", [])
        }.not_to raise_error
      end

      it "passes for runners that support MCP" do
        expect {
          activity.send(:validate_provider_mcp_support!, "claude_code",
            [ { name: "t", transport: "stdio", command: "echo" } ])
        }.not_to raise_error
      end

      it "raises RunnerExecutionError for runners that do not support MCP" do
        expect {
          activity.send(:validate_provider_mcp_support!, "opencode",
            [ { name: "t", transport: "stdio", command: "echo" } ])
        }.to raise_error(
          Activities::RunAgentActivity::RunnerExecutionError,
          /does not support MCP/
        )
      end
    end

    describe "#synchronize_marketplace_mcp_for_runner!" do
      let(:provisioner) { instance_double(Containers::McpProvisioner) }

      before do
        mcp_server_snapshot = []
        mcp_provisioned_servers = nil

        allow(activity).to receive(:marketplace_attachments_attached?).with(agent_run).and_return(true)
        allow(agent_run).to receive(:mcp_server_snapshot) { mcp_server_snapshot }
        allow(agent_run).to receive(:mcp_provisioned_servers) { mcp_provisioned_servers }
        allow(MarketplaceEntries::RerenderForRun).to receive(:call) do
          mcp_server_snapshot << { "name" => "fs" }
        end
        allow(Containers::Provision).to receive(:network_for).with(agent_run: agent_run).and_return("paid-network")
        allow(Containers::McpProvisioner).to receive(:new).and_return(provisioner)
      end

      it "wraps provisioning failures in RunnerExecutionError" do
        allow(provisioner).to receive(:provision).and_raise(StandardError, "boom")

        expect {
          activity.send(
            :synchronize_marketplace_mcp_for_runner!,
            agent_run: agent_run,
            runner_candidate: "claude_code",
            runner: "claude",
            user: user
          )
        }.to raise_error(
          Activities::RunAgentActivity::RunnerExecutionError,
          "Failed to synchronize marketplace MCP servers: boom"
        )
      end

      it "re-raises RunnerExecutionError unchanged" do
        allow(provisioner).to receive(:provision)
          .and_raise(Activities::RunAgentActivity::RunnerExecutionError, "provider failed")

        expect {
          activity.send(
            :synchronize_marketplace_mcp_for_runner!,
            agent_run: agent_run,
            runner_candidate: "claude_code",
            runner: "claude",
            user: user
          )
        }.to raise_error(Activities::RunAgentActivity::RunnerExecutionError, "provider failed")
      end
    end

    context "when executing with MCP servers" do
      before do
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)
      end

      it "passes MCP servers as --mcp-config flag for claude runner" do
        agent_run.update_columns(mcp_provisioned_servers: {
          "stdio_servers" => [ { "name" => "fs", "transport" => "stdio", "command" => "npx-pkg", "args" => [ "/ws" ] } ],
          "url_servers" => []
        })

        expect(container_service).to receive(:execute) do |command, options|
          expect(command).to include("claude")
          expect(command).to include(a_string_starting_with("--mcp-config="))
          expect(command).not_to include("--mcp-config")
          expect(options).to include(timeout: anything)
        end.and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "includes both stdio and url MCP servers in execution" do
        agent_run.update_columns(mcp_provisioned_servers: {
          "stdio_servers" => [ { "name" => "fs", "transport" => "stdio", "command" => "npx-pkg" } ],
          "url_servers" => [ { "name" => "pw", "transport" => "sse", "url" => "http://host:3000/sse" } ]
        })

        expect(container_service).to receive(:execute) do |command, options|
          expect(command).to include("claude")
          expect(command).to include(a_string_starting_with("--mcp-config="))
          expect(command).not_to include("--mcp-config")
          expect(options).to include(timeout: anything)
        end.and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "passes an explicit empty MCP config when no servers are configured" do
        expect(container_service).to receive(:execute) do |command, options|
          # Variadic --mcp-config must use --flag=value so it does not swallow
          # the trailing positional prompt.
          mcp_flag = command.find { |part| part.to_s.start_with?("--mcp-config=") }

          expect(command).to include("claude")
          expect(mcp_flag).to be_present
          expect(command).not_to include("--mcp-config")
          expect(options).to include(timeout: anything)
        end.and_return(exec_success)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "does not reuse a cached plan when MCP servers change between executions" do
        # First call: no MCP servers → plan built with the explicit empty MCP config
        plan_without_mcp = activity.send(:harness_execution_plan_for, "claude_code", "do stuff")

        # Simulate a second execution where MCP servers are now provisioned
        activity.instance_variable_set(:@effective_mcp_servers, [
          { name: "fs", transport: "stdio", command: "npx-pkg", args: [ "/ws" ] }
        ])

        plan_with_mcp = activity.send(:harness_execution_plan_for, "claude_code", "do stuff")

        # The cache must produce distinct plans — not reuse the first one
        expect(plan_with_mcp).not_to eq(plan_without_mcp)
      end
    end
  end
end
