# frozen_string_literal: true

require "rails_helper"

RSpec.describe EnqueueKnowledgeCollectionJob do
  let(:project) { create(:project) }
  let(:commit_sha) { "a" * 40 }
  let(:worktree_service) { instance_double(WorktreeService) }

  before do
    allow(WorktreeService).to receive(:new).with(project).and_return(worktree_service)
    allow(worktree_service).to receive(:ensure_cloned)
    allow(worktree_service).to receive(:current_commit_sha).and_return(commit_sha)
  end

  describe "#perform" do
    it "ensures the repo is cloned" do
      described_class.new.perform(project.id)

      expect(worktree_service).to have_received(:ensure_cloned)
    end

    it "sets knowledge_status to collecting" do
      described_class.new.perform(project.id)

      expect(project.reload.knowledge_status).to eq("collecting")
    end

    it "enqueues RunCollectorsJob with the HEAD SHA" do
      expect {
        described_class.new.perform(project.id)
      }.to have_enqueued_job(RunCollectorsJob).with(project.id, commit_sha, branch: "main")
    end

    it "uses the project default_branch" do
      project.update!(default_branch: "develop")

      expect {
        described_class.new.perform(project.id)
      }.to have_enqueued_job(RunCollectorsJob).with(project.id, commit_sha, branch: "develop")
    end

    it "raises WorktreeService::Error for retry_on to handle" do
      allow(worktree_service).to receive(:ensure_cloned).and_raise(WorktreeService::Error, "not cloned")

      expect { described_class.new.perform(project.id) }.to raise_error(WorktreeService::Error)
    end
  end
end
