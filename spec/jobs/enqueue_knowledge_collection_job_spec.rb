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
    allow(ProjectConventions::DetectForImport).to receive(:call)
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

    it "runs import-time convention detection before enqueuing full collection" do
      described_class.new.perform(project.id)

      expect(ProjectConventions::DetectForImport).to have_received(:call).with(
        project: project,
        commit_sha: commit_sha,
        branch: "main"
      )
    end

    it "still runs import-time convention detection when older conventions already exist" do
      create(
        :project_convention_detection,
        project: project,
        project_version: create(:project_version, project: project, commit_sha: "b" * 40)
      )

      described_class.new.perform(project.id)

      expect(ProjectConventions::DetectForImport).to have_received(:call).with(
        project: project,
        commit_sha: commit_sha,
        branch: "main"
      )
    end

    it "uses the project default_branch" do
      project.update!(default_branch: "develop")

      expect {
        described_class.new.perform(project.id)
      }.to have_enqueued_job(RunCollectorsJob).with(project.id, commit_sha, branch: "develop")
    end

    it "does not overwrite terminal knowledge_status" do
      project.update!(knowledge_status: "ready")

      described_class.new.perform(project.id)

      expect(project.reload.knowledge_status).to eq("ready")
    end

    it "logs and continues when import convention detection fails" do
      allow(ProjectConventions::DetectForImport).to receive(:call).and_raise(StandardError, "boom")
      allow(Rails.logger).to receive(:error)

      expect {
        described_class.new.perform(project.id)
      }.to have_enqueued_job(RunCollectorsJob).with(project.id, commit_sha, branch: "main")

      expect(Rails.logger).to have_received(:error).with(
        hash_including(
          message: "knowledge.import_convention_detection_failed",
          project_id: project.id,
          commit_sha: commit_sha
        )
      )
    end

    it "re-raises import convention checkout errors for retry_on to handle" do
      allow(ProjectConventions::DetectForImport).to receive(:call).and_raise(WorktreeService::Error, "checkout failed")

      expect { described_class.new.perform(project.id) }.to raise_error(WorktreeService::Error, "checkout failed")
    end

    it "re-raises missing checkout errors for retry_on to handle" do
      allow(ProjectConventions::DetectForImport).to receive(:call).and_raise(Errno::ENOENT, "No such file or directory")

      expect { described_class.new.perform(project.id) }.to raise_error(Errno::ENOENT)
    end

    it "raises WorktreeService::Error for retry_on to handle" do
      allow(worktree_service).to receive(:ensure_cloned).and_raise(WorktreeService::Error, "not cloned")

      expect { described_class.new.perform(project.id) }.to raise_error(WorktreeService::Error)
    end
  end

  describe "terminal retry notification" do
    let(:notifier) { instance_double(Paid::ExceptionNotifier) }

    before do
      allow(Paid::ExceptionNotifier).to receive(:new).and_return(notifier)
      allow(notifier).to receive(:call)
    end

    # retry_on intercepts these errors before ApplicationJob's rescue_from hook,
    # so the exhausted final attempt must notify explicitly. Drive the per-
    # exception retry counter to its limit so the next attempt is terminal.
    it "notifies the exception notifier when WorktreeService::Error exhausts retries" do
      allow(worktree_service).to receive(:ensure_cloned).and_raise(WorktreeService::Error, "not cloned")

      job = described_class.new(project.id)
      job.exception_executions = { "[WorktreeService::Error]" => 4 }

      expect { job.perform_now }.to raise_error(WorktreeService::Error)
      expect(notifier).to have_received(:call).with(
        an_instance_of(WorktreeService::Error),
        data: hash_including(subsystem: "knowledge", project_id: project.id)
      )
    end

    it "notifies the exception notifier when Errno::ENOENT exhausts retries" do
      allow(worktree_service).to receive(:ensure_cloned).and_raise(Errno::ENOENT, "missing")

      job = described_class.new(project.id)
      job.exception_executions = { "[Errno::ENOENT]" => 4 }

      expect { job.perform_now }.to raise_error(Errno::ENOENT)
      expect(notifier).to have_received(:call).with(
        an_instance_of(Errno::ENOENT),
        data: hash_including(subsystem: "knowledge", project_id: project.id)
      )
    end

    it "does not notify while retries remain" do
      allow(worktree_service).to receive(:ensure_cloned).and_raise(WorktreeService::Error, "not cloned")

      job = described_class.new(project.id)
      job.exception_executions = { "[WorktreeService::Error]" => 0 }

      # Retries remain, so retry_on reschedules (the :test adapter records the
      # retry without running it) instead of invoking the terminal block.
      expect { job.perform_now }.not_to raise_error
      expect(notifier).not_to have_received(:call)
    end
  end
end
