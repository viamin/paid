# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorktreeOrphanCleanupJob do
  let(:project) { create(:project) }
  let(:job) { described_class.new }

  describe "#perform" do
    it "cleans up orphaned worktrees" do
      completed_run = create(:agent_run, :completed, project: project)
      orphan = create(:worktree, project: project, agent_run: completed_run)

      allow(job).to receive(:worktree_repo_path).and_return("/nonexistent")
      allow(Dir).to receive(:exist?).and_call_original
      allow(Dir).to receive(:exist?).with("/nonexistent").and_return(false)
      allow(Dir).to receive(:exist?).with(orphan.path).and_return(false)

      job.perform

      expect(orphan.reload.status).to eq("cleaned")
    end

    it "prunes active projects" do
      project.update!(active: true)
      repo_path = File.join(WorktreeService::WORKSPACE_ROOT, project.account_id.to_s, project.id.to_s, "repo")

      allow(Dir).to receive(:exist?).and_call_original
      allow(Dir).to receive(:exist?).with(repo_path).and_return(true)
      expect(job).to receive(:system).with("git", "-C", repo_path, "worktree", "prune")

      job.perform
    end

    it "handles errors for individual worktrees gracefully" do
      completed_run = create(:agent_run, :completed, project: project)
      create(:worktree, project: project, agent_run: completed_run)

      allow(job).to receive(:cleanup_worktree).and_raise(StandardError, "cleanup error")
      allow(Dir).to receive(:exist?).and_return(false)

      expect { job.perform }.not_to raise_error
    end
  end
end
