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

    allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
    allow(Containers::Provision).to receive(:reconnect)
      .with(agent_run: agent_run, container_id: "abc123")
      .and_return(container_service)
    allow(Containers::GitOperations).to receive(:new)
      .with(container_service: container_service, agent_run: agent_run)
      .and_return(git_ops)
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
        agent_type: "copilot", container_id: "abc123")
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
          timeout: described_class::ISSUE_GOAL_TIMEOUT,
          idle_timeout: described_class::ISSUE_GOAL_IDLE_TIMEOUT
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
          timeout: Rails.application.config.x.agent_timeout,
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

      it "raises AllProvidersExhausted when all fallbacks fail" do
        allow(container_service).to receive(:execute).and_return(exec_failure)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /All providers exhausted/)
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

        expect {
          activity.execute(agent_run_id: orphan_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /No user available/)
      end
    end
  end
end
