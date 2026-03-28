# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Staleness::Detector do
  let(:project) { create(:project) }
  let(:detector) { described_class.new(project: project) }

  let(:old_sha) { "a" * 40 }
  let(:new_sha) { "b" * 40 }

  let(:worktree_service) { instance_double(WorktreeService) }

  before do
    allow(WorktreeService).to receive(:new).with(project).and_return(worktree_service)
    allow(worktree_service).to receive(:ensure_cloned)
    allow(worktree_service).to receive(:current_commit_sha).and_return(new_sha)
    allow(detector).to receive(:run_git).and_call_original
  end

  describe ".call" do
    it "delegates to #call" do
      detector_instance = instance_double(described_class, call: { stale: false })
      allow(described_class).to receive(:new).and_return(detector_instance)

      result = described_class.call(project: project)
      expect(result[:stale]).to be false
    end
  end

  describe "#call" do
    context "when current SHA cannot be fetched" do
      before do
        allow(worktree_service).to receive(:current_commit_sha)
          .and_raise(WorktreeService::Error, "git failed")
      end

      it "returns not stale" do
        result = detector.call
        expect(result[:stale]).to be false
        expect(result[:current_sha]).to be_nil
      end
    end

    context "when ensure_cloned raises Errno::ENOENT" do
      before do
        allow(worktree_service).to receive(:ensure_cloned)
          .and_raise(Errno::ENOENT, "No such file or directory - /repos/repo")
      end

      it "handles the error and returns not stale" do
        result = detector.call
        expect(result[:stale]).to be false
        expect(result[:current_sha]).to be_nil
      end
    end

    context "when current_commit_sha raises Errno::ENOENT" do
      before do
        allow(worktree_service).to receive(:current_commit_sha)
          .and_raise(Errno::ENOENT, "No such file or directory - /repos/repo")
      end

      it "handles the error and returns not stale" do
        result = detector.call
        expect(result[:stale]).to be false
        expect(result[:current_sha]).to be_nil
      end
    end

    context "when no previous collection exists" do
      it "enqueues initial collection" do
        expect(RunCollectorsJob).to receive(:perform_later)
          .with(project.id, new_sha, branch: project.default_branch)

        result = detector.call
        expect(result[:stale]).to be false
        expect(result[:collection_enqueued]).to be true
        expect(result[:last_collected_sha]).to be_nil
      end

      context "when a ProjectVersion already exists for the SHA" do
        before do
          create(:project_version, project: project, commit_sha: new_sha)
        end

        it "does not enqueue duplicate collection" do
          expect(RunCollectorsJob).not_to receive(:perform_later)

          result = detector.call
          expect(result[:collection_enqueued]).to be false
        end
      end
    end

    context "when HEAD matches last collected version" do
      before do
        version = create(:project_version, project: project, commit_sha: new_sha)
        create(:collector_run, :completed, project_version: version)
      end

      it "returns not stale" do
        result = detector.call
        expect(result[:stale]).to be false
        expect(result[:current_sha]).to eq(new_sha)
        expect(result[:last_collected_sha]).to eq(new_sha)
      end
    end

    context "when HEAD has advanced" do
      let!(:old_version) do
        create(:project_version, project: project, commit_sha: old_sha)
      end
      let!(:completed_run) do
        create(:collector_run, :completed, project_version: old_version)
      end

      before do
        allow(detector).to receive(:run_git)
          .with("rev-list", "--count", "#{old_sha}..#{new_sha}")
          .and_return("3\n")
        allow(detector).to receive(:run_git)
          .with("diff", "--name-only", "#{old_sha}..#{new_sha}")
          .and_return("app/models/user.rb\napp/controllers/users_controller.rb\n")
      end

      it "detects staleness" do
        expect(RunCollectorsJob).to receive(:perform_later)
          .with(project.id, new_sha, branch: project.default_branch)

        result = detector.call
        expect(result[:stale]).to be true
        expect(result[:current_sha]).to eq(new_sha)
        expect(result[:last_collected_sha]).to eq(old_sha)
        expect(result[:changed_files]).to contain_exactly(
          "app/models/user.rb",
          "app/controllers/users_controller.rb"
        )
        expect(result[:collection_enqueued]).to be true
      end

      it "marks only affected artifacts as stale" do
        matching = create(:knowledge_artifact,
          collector_run: completed_run, project: project,
          scope_path: "app/models/user.rb")
        non_matching = create(:knowledge_artifact,
          collector_run: completed_run, project: project,
          scope_path: "app/models/post.rb")

        allow(RunCollectorsJob).to receive(:perform_later)

        result = detector.call

        expect(result[:stale_artifacts_count]).to eq(1)
        expect(matching.reload.status).to eq("stale")
        expect(non_matching.reload.status).to eq("active")
      end

      it "marks associated chunks as stale" do
        artifact = create(:knowledge_artifact,
          collector_run: completed_run, project: project,
          scope_path: "app/models/user.rb")
        chunk = create(:knowledge_chunk,
          knowledge_artifact: artifact, status: "active")

        allow(RunCollectorsJob).to receive(:perform_later)
        detector.call

        expect(chunk.reload.status).to eq("stale")
      end

      it "does not mark artifacts from an in-progress collection as stale" do
        # Artifact from the old (completed) version — should be staled
        old_artifact = create(:knowledge_artifact,
          collector_run: completed_run, project: project,
          scope_path: "app/models/user.rb")

        # Simulate an in-progress collection for new_sha
        new_version = create(:project_version, project: project, commit_sha: new_sha)
        in_progress_run = create(:collector_run, project_version: new_version)
        new_artifact = create(:knowledge_artifact,
          collector_run: in_progress_run, project: project,
          scope_path: "app/models/user.rb")

        allow(RunCollectorsJob).to receive(:perform_later)

        detector.call

        expect(old_artifact.reload.status).to eq("stale")
        expect(new_artifact.reload.status).to eq("active")
      end

      it "does not mark already-stale artifacts" do
        create(:knowledge_artifact, :stale,
          collector_run: completed_run, project: project,
          scope_path: "app/models/user.rb")

        allow(RunCollectorsJob).to receive(:perform_later)

        result = detector.call
        expect(result[:stale_artifacts_count]).to eq(0)
      end
    end

    context "when below staleness threshold" do
      before do
        old_version = create(:project_version, project: project, commit_sha: old_sha)
        create(:collector_run, :completed, project_version: old_version)

        stub_const("Knowledge::Staleness::Detector::STALENESS_THRESHOLD", 5)
        allow(detector).to receive(:run_git)
          .with("rev-list", "--count", "#{old_sha}..#{new_sha}")
          .and_return("3\n")
      end

      it "returns not stale" do
        result = detector.call
        expect(result[:stale]).to be false
      end
    end

    context "when git operations fail" do
      before do
        old_version = create(:project_version, project: project, commit_sha: old_sha)
        create(:collector_run, :completed, project_version: old_version)
      end

      it "handles rev-list failure gracefully" do
        allow(detector).to receive(:run_git)
          .with("rev-list", "--count", "#{old_sha}..#{new_sha}")
          .and_raise(WorktreeService::Error, "git failed")
        allow(detector).to receive(:run_git)
          .with("diff", "--name-only", "#{old_sha}..#{new_sha}")
          .and_return("")

        allow(RunCollectorsJob).to receive(:perform_later)

        result = detector.call
        expect(result[:stale]).to be true
      end

      it "handles diff failure gracefully" do
        allow(detector).to receive(:run_git)
          .with("rev-list", "--count", "#{old_sha}..#{new_sha}")
          .and_return("3\n")
        allow(detector).to receive(:run_git)
          .with("diff", "--name-only", "#{old_sha}..#{new_sha}")
          .and_raise(WorktreeService::Error, "git failed")

        allow(RunCollectorsJob).to receive(:perform_later)

        result = detector.call
        expect(result[:stale]).to be true
        expect(result[:changed_files]).to eq([])
        expect(result[:stale_artifacts_count]).to eq(0)
      end
    end

    context "when collection already exists for target SHA" do
      before do
        old_version = create(:project_version, project: project, commit_sha: old_sha)
        create(:collector_run, :completed, project_version: old_version)

        # Already have a version for new_sha (collection in progress)
        create(:project_version, project: project, commit_sha: new_sha)

        allow(detector).to receive(:run_git)
          .with("rev-list", "--count", "#{old_sha}..#{new_sha}")
          .and_return("3\n")
        allow(detector).to receive(:run_git)
          .with("diff", "--name-only", "#{old_sha}..#{new_sha}")
          .and_return("app/models/user.rb\n")
      end

      it "does not enqueue duplicate collection for same version" do
        expect(RunCollectorsJob).not_to receive(:perform_later)

        result = detector.call
        expect(result[:stale]).to be true
        expect(result[:collection_enqueued]).to be false
      end
    end
  end
end
