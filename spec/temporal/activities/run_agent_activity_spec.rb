# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RunAgentActivity do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) { create(:agent_run, :with_git_context, project: project, issue: issue) }
  let(:activity) { described_class.new }
  let(:prompt) { "Fix the bug described in the issue" }
  let(:execute_result) { AgentRuns::Execute::Result.new(success: true) }
  let(:git_status_result) { Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0) }
  let(:git_log_result) { Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0) }

  describe "#execute" do
    before do
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      allow(agent_run).to receive_messages(prompt_for_issue: prompt, execute_agent: execute_result)
      allow(agent_run).to receive(:execute_in_container)
        .with("git status --porcelain", stream: false)
        .and_return(git_status_result)
      allow(agent_run).to receive(:execute_in_container)
        .with("git log origin/HEAD..HEAD --oneline 2>/dev/null || true", stream: false)
        .and_return(git_log_result)
    end

    it "executes the agent and returns result" do
      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:agent_run_id]).to eq(agent_run.id)
      expect(result[:success]).to be true
      expect(result[:has_changes]).to be false
    end

    context "when agent produces changes" do
      let(:git_status_result) do
        Containers::Provision::Result.success(stdout: "M app/models/user.rb\n", stderr: "", exit_code: 0)
      end

      it "reports has_changes as true" do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
      end
    end

    context "when agent produces new commits" do
      let(:git_log_result) do
        Containers::Provision::Result.success(stdout: "abc1234 Fix the bug\n", stderr: "", exit_code: 0)
      end

      it "reports has_changes as true" do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:has_changes]).to be true
      end
    end

    it "raises when no prompt can be built" do
      allow(agent_run).to receive(:prompt_for_issue).and_return(nil)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(RuntimeError, /No prompt/)
    end
  end

  it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
    expect {
      activity.execute(agent_run_id: -1)
    }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
