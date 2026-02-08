# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::PushBranchActivity do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :with_git_context, project: project) }
  let(:activity) { described_class.new }
  let(:commit_sha) { "abc123def456789012345678901234567890abcd" }
  let(:worktree_service) { instance_double(WorktreeService) }

  describe "#execute" do
    it "pushes the branch and returns commit SHA" do
      allow(WorktreeService).to receive(:new).with(project).and_return(worktree_service)
      expect(worktree_service).to receive(:push_branch)
        .with(agent_run)
        .and_return(commit_sha)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:commit_sha]).to eq(commit_sha)
      expect(result[:agent_run_id]).to eq(agent_run.id)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect { activity.execute(agent_run_id: -1) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
