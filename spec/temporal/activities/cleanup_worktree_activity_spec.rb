# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CleanupWorktreeActivity do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :with_git_context, project: project) }
  let(:activity) { described_class.new }
  let(:worktree_service) { instance_double(WorktreeService) }

  describe "#execute" do
    it "removes the worktree for the agent run" do
      allow(WorktreeService).to receive(:new).with(project).and_return(worktree_service)
      expect(worktree_service).to receive(:remove_worktree)
        .with(agent_run)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:agent_run_id]).to eq(agent_run.id)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect { activity.execute(agent_run_id: -1) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
