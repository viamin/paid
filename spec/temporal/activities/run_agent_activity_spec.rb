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

  describe "AGENT_COMMANDS" do
    it "includes a command mapping for codex" do
      expect(described_class::AGENT_COMMANDS).to have_key("codex")
      expect(described_class::AGENT_COMMANDS["codex"]).to include("codex")
    end

    it "uses codex exec subcommand for non-interactive mode" do
      cmd = described_class::AGENT_COMMANDS["codex"]
      expect(cmd).to start_with("codex", "exec", "--full-auto")
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
      expect(described_class::AGENT_COMMANDS["opencode"]).to include("opencode")
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
      command = activity.send(:build_command, "codex", described_class::AGENT_COMMANDS["codex"], "say 'hi'")
      script = command[2]

      expect(command[0..1]).to eq(%w[sh -c])
      expect(script).to include('if [ "$PAID_CODEX_SUBSCRIPTION_AUTH" = "1" ]')
      expect(script).to include("-u OPENAI_API_KEY")
      expect(script).to include("codex exec --full-auto --")
      expect(command[3]).to eq("--")
      expect(command[4]).to eq("say 'hi'")
    end

    it "builds a sh -c wrapper for Gemini subscription auth" do
      command = activity.send(:build_command, "gemini", described_class::AGENT_COMMANDS["gemini"], "say 'hi'")
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
      command = activity.send(:build_command, "codex", described_class::AGENT_COMMANDS["codex"], multiline_prompt)

      expect(command[4]).to eq(multiline_prompt)
      expect(command[2]).not_to include("\n")
    end

    it "keeps non-subscription providers in array form" do
      command = activity.send(:build_command, "claude", described_class::AGENT_COMMANDS["claude"], "ping")

      expect(command).to eq(described_class::AGENT_COMMANDS["claude"] + [ "ping" ])
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
          timeout: described_class::DEFAULT_ISSUE_GOAL_TIMEOUT,
          idle_timeout: described_class::DEFAULT_ISSUE_GOAL_IDLE_TIMEOUT
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
        allow(container_service).to receive(:execute).and_return(exec_success)
        allow(git_ops).to receive_messages(head_sha: "sha123", commit_uncommitted_changes: false, has_changes_since?: false)

        expect(container_service).to receive(:execute).with(
          anything,
          timeout: AGENT_TIMEOUT_DEFAULT,
          idle_timeout: nil
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
end
