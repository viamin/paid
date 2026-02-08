# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RunAgentActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) { create(:agent_run, :with_git_context, :with_issue, project: project, issue: issue) }
  let(:execute_result) { AgentRuns::Execute::Result.new(success: true) }
  let(:container_result) { Containers::Provision::Result.success(stdout: "file.rb | 5 +\n", stderr: "", exit_code: 0) }
  let(:empty_result) { Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0) }

  before do
    allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
    allow(agent_run).to receive(:execute_agent).and_return(execute_result)
  end

  describe "#execute" do
    it "builds a prompt and executes the agent" do
      allow(agent_run).to receive(:execute_in_container).and_return(empty_result)

      expect(agent_run).to receive(:prompt_for_issue).and_call_original
      expect(agent_run).to receive(:execute_agent)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "returns has_changes: true when the agent made changes" do
      allow(agent_run).to receive(:execute_in_container).and_return(container_result)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:has_changes]).to be true
      expect(result[:success]).to be true
    end

    it "returns has_changes: false when the agent made no changes" do
      allow(agent_run).to receive(:execute_in_container).and_return(empty_result)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:has_changes]).to be false
    end

    it "raises an error when no issue is attached" do
      agent_run_no_issue = create(:agent_run, project: project)
      allow(AgentRun).to receive(:find).with(agent_run_no_issue.id).and_return(agent_run_no_issue)

      expect {
        activity.execute(agent_run_id: agent_run_no_issue.id)
      }.to raise_error(Temporalio::Error::ApplicationError, /No issue attached/)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      allow(AgentRun).to receive(:find).and_call_original

      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
