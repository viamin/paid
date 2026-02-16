# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RunAgentActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) { create(:agent_run, :with_git_context, project: project, issue: issue, container_id: "abc123") }
  let(:success_result) { AgentRuns::Execute::Result.new(success: true) }
  let(:failure_result) { AgentRuns::Execute::Result.new(success: false, error: "Agent crashed") }
  let(:container_service) { instance_double(Containers::Provision) }
  let(:git_ops) { instance_double(Containers::GitOperations) }

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
    context "when agent succeeds" do
      before do
        allow(agent_run).to receive(:execute_agent).and_return(success_result)
      end

      it "builds a prompt and executes the agent" do
        allow(git_ops).to receive(:has_changes?).and_return(false)

        expect(agent_run).to receive(:prompt_for_issue).and_call_original
        expect(agent_run).to receive(:execute_agent)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "returns has_changes: true when container git diff shows changes" do
        allow(git_ops).to receive(:has_changes?).and_return(true)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
        expect(result[:success]).to be true
      end

      it "returns has_changes: false when container git diff is empty" do
        allow(git_ops).to receive(:has_changes?).and_return(false)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be false
        expect(result[:success]).to be true
      end

      it "returns has_changes: false when container check fails" do
        allow(git_ops).to receive(:has_changes?).and_raise(StandardError, "container gone")

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be false
      end
    end

    context "when agent fails" do
      before do
        allow(agent_run).to receive(:execute_agent).and_return(failure_result)
      end

      it "raises an ApplicationError" do
        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /Agent execution failed/)
      end
    end

    it "raises an error when no prompt is available" do
      agent_run_no_prompt = create(:agent_run, :with_custom_prompt, project: project)
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
  end
end
