# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RunAgentActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) { create(:agent_run, :with_git_context, project: project, issue: issue, container_id: "abc123") }
  let(:container_service) { instance_double(Containers::Provision) }
  let(:git_ops) { instance_double(Containers::GitOperations) }
  let(:exec_success) { Containers::Provision::Result.success(stdout: "Done", stderr: "", exit_code: 0) }
  let(:exec_failure) { Containers::Provision::Result.failure(error: "exit 1", stdout: "", stderr: "error", exit_code: 1) }

  before do
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
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
      end

      it "executes the agent CLI inside the container" do
        allow(git_ops).to receive(:has_changes_since?).and_return(false)

        expect(container_service).to receive(:execute).with(
          array_including("claude", "--print", "--output-format=text", "--dangerously-skip-permissions", "-p"),
          timeout: anything
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

      it "falls back to has_changes? when pre_agent_sha capture fails" do
        allow(git_ops).to receive(:head_sha).and_raise(StandardError, "container not ready")
        allow(git_ops).to receive(:has_changes?).and_return(true)
        allow(git_ops).to receive(:has_changes_since?)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(git_ops).not_to have_received(:has_changes_since?)
      end
    end

    context "when agent fails in container" do
      before do
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute).and_return(exec_failure)
      end

      it "raises an ApplicationError" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /Agent execution failed/)
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

    context "when agent times out" do
      before do
        allow(git_ops).to receive(:head_sha).and_return("pre_agent_sha_abc123")
        allow(container_service).to receive(:execute)
          .and_raise(Containers::Provision::TimeoutError)
      end

      it "raises an ApplicationError with timeout type" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /timed out/i)
      end

      it "marks the agent run as timed out" do
        begin
          activity.execute(agent_run_id: agent_run.id)
        rescue Temporalio::Error::ApplicationError
          # expected
        end

        expect(agent_run.reload.status).to eq("timeout")
      end
    end

    context "when no container is provisioned" do
      let(:agent_run_no_container) do
        create(:agent_run, :with_git_context, project: project, issue: issue, container_id: nil)
      end

      it "raises an ApplicationError" do
        allow(AgentRun).to receive(:find).with(agent_run_no_container.id).and_return(agent_run_no_container)

        expect {
          activity.execute(agent_run_id: agent_run_no_container.id)
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
      unsupported_run = create(:agent_run, project: project, issue: issue,
        agent_type: "cursor", container_id: "abc123")
      allow(AgentRun).to receive(:find).with(unsupported_run.id).and_return(unsupported_run)
      allow(Containers::Provision).to receive(:reconnect)
        .with(agent_run: unsupported_run, container_id: "abc123")
        .and_return(container_service)

      expect {
        activity.execute(agent_run_id: unsupported_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError, /Unsupported agent type/)
    end
  end
end
