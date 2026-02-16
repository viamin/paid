# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CleanupWorktreeActivity do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :with_git_context, project: project) }
  let(:activity) { described_class.new }

  describe "#execute" do
    it "marks the worktree record as cleaned" do
      worktree = create(:worktree, project: project, agent_run: agent_run, status: "active")

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:agent_run_id]).to eq(agent_run.id)
      expect(worktree.reload.status).to eq("cleaned")
    end

    it "handles agent runs without a worktree record" do
      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:agent_run_id]).to eq(agent_run.id)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect { activity.execute(agent_run_id: -1) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
