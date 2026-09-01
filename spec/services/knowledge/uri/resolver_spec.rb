# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Uri::Resolver do
  # @spec KNOWLEDGE-URI-002
  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project: project, commit_sha: "a" * 40) }
  let(:collector_run) { create(:collector_run, project_version: project_version) }
  let(:artifact) do
    create(:knowledge_artifact,
      project: project, collector_run: collector_run,
      artifact_type: "route", scope_path: "config/routes.rb", identifier: "GET /x")
  end
  let(:chunk) { create(:knowledge_chunk, project: project, knowledge_artifact: artifact) }

  describe ".call" do
    it "resolves a chunk uri to its KnowledgeChunk" do
      resolved = described_class.call(chunk.knowledge_uri, project: project)

      expect(resolved).to eq(chunk)
    end

    it "resolves an active-view artifact uri to its KnowledgeArtifact" do
      resolved = described_class.call(artifact.knowledge_uri, project: project)

      expect(resolved).to eq(artifact)
    end

    it "resolves a commit-pinned artifact uri even after the artifact goes stale" do
      uri = artifact.versioned_knowledge_uri
      artifact.update!(status: "stale")

      resolved = described_class.call(uri, project: project)

      expect(resolved).to eq(artifact)
    end

    it "does not resolve a stale artifact through the active-view uri" do
      uri = artifact.knowledge_uri
      artifact.update!(status: "stale")

      expect(described_class.call(uri, project: project)).to be_nil
    end

    it "returns nil when nothing matches" do
      missing_uri = Knowledge::Uri.build_chunk(project_id: project.id, chunk_id: SecureRandom.uuid)

      expect(described_class.call(missing_uri, project: project)).to be_nil
    end

    it "raises ProjectMismatchError when the uri belongs to a different project" do
      other_project = create(:project)

      expect { described_class.call(chunk.knowledge_uri, project: other_project) }
        .to raise_error(Knowledge::Uri::Resolver::ProjectMismatchError)
    end

    it "does not resolve a chunk belonging to another project even with a matching id" do
      other_project = create(:project)
      other_artifact = create(:knowledge_artifact, project: other_project, collector_run: create(:collector_run, project_version: create(:project_version, project: other_project)))
      other_chunk = create(:knowledge_chunk, project: other_project, knowledge_artifact: other_artifact)
      forged_uri = Knowledge::Uri.build_chunk(project_id: project.id, chunk_id: other_chunk.id)

      expect(described_class.call(forged_uri, project: project)).to be_nil
    end

    it "resolves an artifact with a blank identifier through its uri" do
      blank_artifact = create(:knowledge_artifact,
        project: project, collector_run: collector_run,
        artifact_type: "language_stat", scope_path: "config/routes.rb", identifier: "")

      resolved = described_class.call(blank_artifact.knowledge_uri, project: project)

      expect(resolved).to eq(blank_artifact)
    end

    it "resolves an artifact with a blank scope_path through its uri" do
      blank_artifact = create(:knowledge_artifact,
        project: project, collector_run: collector_run,
        artifact_type: "language_stat", scope_path: "", identifier: "Ruby")

      resolved = described_class.call(blank_artifact.knowledge_uri, project: project)

      expect(resolved).to eq(blank_artifact)
    end
  end
end
