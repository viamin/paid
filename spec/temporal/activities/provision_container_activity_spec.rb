# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ProvisionContainerActivity do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :with_git_context, project: project) }
  let(:activity) { described_class.new }
  let(:container_result) { Containers::Provision::Result.success(container_id: "abc123") }

  describe "#execute" do
    it "provisions a container for the agent run" do
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      allow(agent_run).to receive(:provision_container).and_return(container_result)

      result = activity.execute(
        agent_run_id: agent_run.id,
        worktree_path: agent_run.worktree_path
      )

      expect(result[:agent_run_id]).to eq(agent_run.id)
      expect(result[:container_id]).to eq("abc123")
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1, worktree_path: "/tmp/test")
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
