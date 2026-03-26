# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ArtifactStore do
  subject(:store) { described_class.new(project: project, collector_run: collector_run) }

  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, project_version: project_version, collector_type: "test") }

  let(:artifact_data) do
    {
      artifact_type: "route",
      scope_path: "config/routes.rb",
      identifier: "GET /api/users",
      content: '{"method": "GET", "path": "/api/users"}',
      metadata: { line: 10 },
      chunks: [
        { chunk_type: "definition", content: "get '/api/users', to: 'users#index'", scope_tags: [ "api" ] }
      ]
    }
  end


  describe "#store_all" do
    it "creates an artifact with chunks" do
      count = store.store_all([ artifact_data ])

      expect(count).to eq(1)
      expect(KnowledgeArtifact.count).to eq(1)
      expect(KnowledgeChunk.count).to eq(1)

      artifact = KnowledgeArtifact.first
      expect(artifact.artifact_type).to eq("route")
      expect(artifact.content_hash).to be_present
      expect(artifact.status).to eq("active")
    end

    context "when storing identical content again (same hash)" do
      let(:new_version) { create(:project_version, project: project) }
      let(:new_run) { create(:collector_run, project_version: new_version, collector_type: "test") }

      it "reassigns the existing artifact to the new run" do
        store.store_all([ artifact_data ])
        expect(KnowledgeArtifact.count).to eq(1)

        new_store = described_class.new(project: project, collector_run: new_run)
        new_store.store_all([ artifact_data ])

        expect(KnowledgeArtifact.count).to eq(1)
        expect(KnowledgeArtifact.first.collector_run).to eq(new_run)
      end
    end

    context "when content changes (different hash)" do
      let(:new_version) { create(:project_version, project: project) }
      let(:new_run) { create(:collector_run, project_version: new_version, collector_type: "test") }

      let(:updated_data) do
        artifact_data.merge(content: '{"method": "GET", "path": "/api/users", "auth": true}')
      end

      it "creates a new artifact and marks the old one stale" do
        store.store_all([ artifact_data ])
        expect(KnowledgeArtifact.active.count).to eq(1)

        new_store = described_class.new(project: project, collector_run: new_run)
        new_store.store_all([ updated_data ])

        expect(KnowledgeArtifact.count).to eq(2)
        expect(KnowledgeArtifact.active.count).to eq(1)
        expect(KnowledgeArtifact.stale.count).to eq(1)
        expect(KnowledgeArtifact.active.first.collector_run).to eq(new_run)
      end
    end
  end
end
