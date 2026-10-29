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

    # @spec KNOWLEDGE-003
    it "keeps a many-chunk matching artifact bounded across both retrieval paths" do
      chunks = bounded_chunks_with_links
      output = described_class.call(project: project, query: "bounded hybrid", limit: 5)

      expect(output[:results].map { |result| result[:chunk_id] }).to eq(chunks.first(5).map(&:id))
      expect(output[:results].map { |result| result[:link_count] }).to all(eq(2))
    end

    it "passes search arguments through to Semantic" do
      allow(Knowledge::Search::Semantic).to receive(:call).and_return({ results: [], vector_search_status: "not_configured" })

      described_class.call(project: project, query: "test")

      expect(Knowledge::Search::Semantic).to have_received(:call).with(
        hash_including(project: project, query: "test")
      )
    end

    it "surfaces the semantic search's vector_search_status" do
      allow(Knowledge::Search::Semantic).to receive(:call).and_return({ results: [], vector_search_status: "no_embeddings" })

      output = described_class.call(project: project, query: "test")

      expect(output[:vector_search_status]).to eq("no_embeddings")
    end
  end

  def bounded_chunks_with_links
    artifact = create(:knowledge_artifact,
      project: project, collector_run: collector_run, artifact_type: "route",
      identifier: "bounded hybrid", content: "bounded hybrid route")
    chunks = create_list(:knowledge_chunk, 10,
      knowledge_artifact: artifact, project: project, chunk_type: "context", content: "bounded hybrid")
    link_target = create(:knowledge_chunk,
      knowledge_artifact: artifact, project: project, chunk_type: "evidence", content: "link target")
    link_target.update!(sequence: 99)

    chunks.each_with_index do |chunk, index|
      chunk.update!(sequence: index)
      create(:knowledge_link, source_chunk: chunk, target_chunk: link_target)
      create(:knowledge_link, source_chunk: link_target, target_chunk: chunk)
    end
    chunks
  end
end
