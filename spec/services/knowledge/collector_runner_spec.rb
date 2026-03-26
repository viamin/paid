# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::CollectorRunner do
  let(:project) { create(:project) }
  let(:commit_sha) { "a" * 40 }

  # Test collector that returns predictable data
  let(:test_collector_class) do
    Class.new(Knowledge::BaseCollector) do
      def collect
        [
          {
            artifact_type: "test_artifact",
            scope_path: "app/models/user.rb",
            identifier: "User",
            content: '{"class": "User"}',
            metadata: {},
            chunks: [
              { chunk_type: "definition", content: "class User < ApplicationRecord", scope_tags: [ "model" ] }
            ]
          }
        ]
      end

      def collector_type
        "test_collector"
      end

      def tool_version
        "test-tool 1.0.0"
      end
    end
  end

  before do
    described_class.reset_registry!
    described_class.register("test_collector", test_collector_class)
  end

  after do
    described_class.reset_registry!
  end

  describe ".call" do
    it "creates a project version and runs collectors" do
      result = described_class.call(project: project, commit_sha: commit_sha)

      expect(result[:project_version]).to be_persisted
      expect(result[:project_version].commit_sha).to eq(commit_sha)
      expect(result[:results].size).to eq(1)
      expect(result[:results].first[:status]).to eq("completed")
      expect(result[:results].first[:artifacts_count]).to eq(1)
    end

    it "creates artifacts and chunks" do
      described_class.call(project: project, commit_sha: commit_sha)

      expect(KnowledgeArtifact.count).to eq(1)
      artifact = KnowledgeArtifact.first
      expect(artifact.artifact_type).to eq("test_artifact")
      expect(artifact.identifier).to eq("User")
      expect(artifact.status).to eq("active")

      expect(KnowledgeChunk.count).to eq(1)
      chunk = KnowledgeChunk.first
      expect(chunk.chunk_type).to eq("definition")
    end

    it "records collector run with tool_version and duration" do
      described_class.call(project: project, commit_sha: commit_sha)

      run = CollectorRun.first
      expect(run.status).to eq("completed")
      expect(run.tool_version).to eq("test-tool 1.0.0")
      expect(run.duration_ms).to be_present
      expect(run.artifacts_count).to eq(1)
    end

    context "when run twice on the same commit (idempotency)" do
      it "produces identical artifact counts" do
        result1 = described_class.call(project: project, commit_sha: commit_sha)
        result2 = described_class.call(project: project, commit_sha: commit_sha)

        expect(result2[:results].first[:status]).to eq("skipped")
        expect(KnowledgeArtifact.active.count).to eq(1)
      end

      it "reuses the same project version" do
        result1 = described_class.call(project: project, commit_sha: commit_sha)
        result2 = described_class.call(project: project, commit_sha: commit_sha)

        expect(result1[:project_version].id).to eq(result2[:project_version].id)
      end
    end

    context "when advancing to a new commit" do
      let(:new_commit_sha) { "b" * 40 }

      it "marks artifacts not collected by the new version as stale" do
        # Run on old commit — creates an artifact via test_collector
        described_class.call(project: project, commit_sha: commit_sha)

        # Manually create an extra artifact on the old version's run
        # that the new version's collector won't produce
        old_run = CollectorRun.first
        extra = KnowledgeArtifact.create!(
          collector_run: old_run,
          project: project,
          collector_type: old_run.collector_type,
          artifact_type: "orphaned_type",
          identifier: "OrphanedThing",
          content: "old content",
          content_hash: Digest::SHA256.hexdigest("old content"),
          status: "active"
        )

        expect(KnowledgeArtifact.active.count).to eq(2)

        # Run on new commit — the test_collector artifact gets reassigned,
        # but the extra artifact is not produced so it becomes stale
        described_class.call(project: project, commit_sha: new_commit_sha)

        extra.reload
        expect(extra.status).to eq("stale")
        expect(KnowledgeArtifact.active.count).to eq(1)
      end
    end

    context "when a collector fails" do
      let(:failing_collector_class) do
        Class.new(Knowledge::BaseCollector) do
          def collect
            raise "tool not found"
          end

          def collector_type
            "failing_collector"
          end
        end
      end

      before do
        described_class.reset_registry!
        described_class.register("failing_collector", failing_collector_class)
        described_class.register("test_collector", test_collector_class)
      end

      it "does not block other collectors" do
        result = described_class.call(project: project, commit_sha: commit_sha)

        statuses = result[:results].map { |r| r[:status] }
        expect(statuses).to contain_exactly("failed", "completed")
      end

      it "records the failure on the collector run" do
        described_class.call(project: project, commit_sha: commit_sha)

        failed_run = CollectorRun.find_by(collector_type: "failing_collector")
        expect(failed_run.status).to eq("failed")
        expect(failed_run.error_message).to eq("tool not found")
      end

      it "does not mark prior artifacts as stale when a collector fails" do
        old_sha = "c" * 40
        described_class.call(project: project, commit_sha: old_sha)

        old_run = CollectorRun.find_by(collector_type: "test_collector")
        extra = create(:knowledge_artifact,
          collector_run: old_run, project: project,
          collector_type: old_run.collector_type, artifact_type: "orphaned_type",
          identifier: "OrphanedThing", content: "old", content_hash: Digest::SHA256.hexdigest("old"))

        # Run on new commit with both collectors (one will fail)
        described_class.register("failing_collector", failing_collector_class)
        new_sha = "d" * 40
        described_class.call(project: project, commit_sha: new_sha)

        # Extra artifact from old version stays active since the run had a failure
        expect(extra.reload.status).to eq("active")
      end
    end
  end
end
