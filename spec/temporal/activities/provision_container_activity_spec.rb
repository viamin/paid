# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ProvisionContainerActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :with_git_context, project: project) }

  describe "#execute" do
    it "provisions a container for the agent run" do
      expect(agent_run).to receive(:ensure_proxy_token!).and_return("token")
      expect(agent_run).to receive(:provision_container)
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

      result = activity.execute(agent_run_id: agent_run.id, worktree_path: agent_run.worktree_path)

      expect(result[:agent_run_id]).to eq(agent_run.id)
      expect(result[:worktree_path]).to eq(agent_run.worktree_path)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1, worktree_path: "/tmp/test")
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
