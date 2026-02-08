# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreateWorktreeActivity do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:activity) { described_class.new }
  let(:worktree_path) { "/var/paid/workspaces/#{project.account_id}/#{project.id}/worktrees/test" }
  let(:worktree_service) { instance_double(WorktreeService) }

  describe "#execute" do
    it "creates a worktree for the agent run" do
      allow(WorktreeService).to receive(:new).with(project).and_return(worktree_service)
      expect(worktree_service).to receive(:create_worktree)
        .with(agent_run)
        .and_return(worktree_path)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:worktree_path]).to eq(worktree_path)
      expect(result[:agent_run_id]).to eq(agent_run.id)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect { activity.execute(agent_run_id: -1) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
