# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Search::Semantic do
  include_context "without qdrant vector search"

  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project: project, commit_sha: "abc123") }
  let(:collector_run) { create(:collector_run, project_version: project_version, collector_type: "routes") }

  let!(:route_artifact) do
    create(:knowledge_artifact,
      project: project,
      collector_run: collector_run,
      artifact_type: "route",
      identifier: "GET /api/users",
      content: "GET /api/users → api/users#index",
      scope_path: "config/routes.rb")
  end

  before do
    create(:knowledge_chunk,
      knowledge_artifact: route_artifact,
      project: project,
      chunk_type: "definition",
      content: "Route: GET /api/users\nController: api/users#index\nPurpose: Lists all users")
  end

  describe "#call" do
    context "with lexical search" do
      it "finds chunks via full-text search" do
        results = described_class.call(project: project, query: "lists all users")

        expect(results).not_to be_empty
        expect(results.first[:source]).to eq("semantic")
      end

      it "returns results with artifact info" do
        results = described_class.call(project: project, query: "users route controller")

        expect(results).not_to be_empty
        expect(results.first[:artifact_type]).to eq("route")
        expect(results.first[:identifier]).to eq("GET /api/users")
      end

      it "includes scope_tags and scoring fields" do
        results = described_class.call(project: project, query: "lists all users")

        expect(results.first).to have_key(:scope_tags)
        expect(results.first).to have_key(:link_count)
        expect(results.first).to have_key(:created_at)
      end

      it "filters by artifact_type" do
        dep_artifact = create(:knowledge_artifact,
          project: project,
          collector_run: collector_run,
          artifact_type: "dependency",
          identifier: "rails",
          content: "rails dependency")
        create(:knowledge_chunk,
          knowledge_artifact: dep_artifact,
          project: project,
          chunk_type: "definition",
          content: "Lists all dependencies for users")

        results = described_class.call(
          project: project,
          query: "lists all users",
          artifact_type: "route"
        )

        expect(results.map { |r| r[:artifact_type] }).to all(eq("route"))
      end
    end

    context "with vector search unavailable" do
      it "still returns lexical results" do
        results = described_class.call(project: project, query: "lists all users")

        expect(results).not_to be_empty
      end
    end

    context "with api_key parameter" do
      it "passes api_key to Generate.call for query embedding" do
        allow(Paid).to receive_messages(qdrant_url: "http://localhost:6333", qdrant_client: double(healthy?: true))
        allow(Knowledge::Embeddings::Generate).to receive(:call).and_return([])

        described_class.call(project: project, query: "test", api_key: "sk-user-key")

        expect(Knowledge::Embeddings::Generate).to have_received(:call).with(
          texts: [ "test" ], api_key: "sk-user-key"
        )
      end

      it "passes nil api_key when none provided" do
        allow(Paid).to receive_messages(qdrant_url: "http://localhost:6333", qdrant_client: double(healthy?: true))
        allow(Knowledge::Embeddings::Generate).to receive(:call).and_return([])

        described_class.call(project: project, query: "test")

        expect(Knowledge::Embeddings::Generate).to have_received(:call).with(
          texts: [ "test" ], api_key: nil
        )
      end
    end
  end
end
