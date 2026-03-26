# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Search::Hybrid do
  include_context "without qdrant vector search"

  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project: project, commit_sha: "abc123") }
  let(:collector_run) { create(:collector_run, project_version: project_version, collector_type: "routes") }

  let!(:route_artifact) do
    create(:knowledge_artifact,
      project: project,
      collector_run: collector_run,
      artifact_type: "route",
      identifier: "POST /api/users",
      content: "POST /api/users → api/users#create",
      scope_path: "config/routes.rb")
  end

  let!(:get_artifact) do
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
      content: "Route: POST /api/users\nController: api/users#create")

    create(:knowledge_chunk,
      knowledge_artifact: get_artifact,
      project: project,
      chunk_type: "definition",
      content: "Route: GET /api/users\nController: api/users#index\nPurpose: Lists all users")
  end

  describe "#call" do
    it "merges exact and semantic results" do
      output = described_class.call(project: project, query: "POST /api/users")

      expect(output[:results]).not_to be_empty
    end

    it "deduplicates results across modes" do
      output = described_class.call(project: project, query: "POST /api/users")

      chunk_ids = output[:results].map { |r| r[:chunk_id] }
      expect(chunk_ids.uniq.length).to eq(chunk_ids.length)
    end

    it "returns exact and semantic counts" do
      output = described_class.call(project: project, query: "POST /api/users")

      expect(output).to have_key(:exact_count)
      expect(output).to have_key(:semantic_count)
    end

    it "sets source to hybrid for all results" do
      output = described_class.call(project: project, query: "POST /api/users")

      sources = output[:results].map { |r| r[:source] }
      expect(sources).to all(eq("hybrid"))
    end

    it "ranks results with matching version higher" do
      output = described_class.call(
        project: project,
        query: "POST /api/users",
        version: "abc123"
      )

      expect(output[:results]).not_to be_empty
      scores = output[:results].map { |r| r[:score] }
      expect(scores).to all(be > 0)
    end

    it "respects limit" do
      output = described_class.call(project: project, query: "api", limit: 1)

      expect(output[:results].length).to be <= 1
    end
  end
end
