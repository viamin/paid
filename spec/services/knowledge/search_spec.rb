# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-003
# @spec KNOWLEDGE-005
RSpec.describe Knowledge::Search do
  include_context "without qdrant vector search"

  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project, issue: create(:issue, project: project)) }
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

  let!(:route_chunk) do
    create(:knowledge_chunk,
      knowledge_artifact: route_artifact,
      project: project,
      chunk_type: "definition",
      content: "Route: POST /api/users\nController: api/users#create\nAuthentication: signs users in")
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

  let(:get_chunk) do
    create(:knowledge_chunk,
      knowledge_artifact: get_artifact,
      project: project,
      chunk_type: "definition",
      content: "Route: GET /api/users\nController: api/users#index\nPurpose: Lists all users")
  end

  let!(:symbol_artifact) do
    create(:knowledge_artifact,
      project: project,
      collector_run: collector_run,
      artifact_type: "symbol",
      identifier: "app/models/user.rb::User",
      content: "User model",
      scope_path: "app/models/user.rb")
  end

  let(:symbol_chunk) do
    create(:knowledge_chunk,
      knowledge_artifact: symbol_artifact,
      project: project,
      chunk_type: "definition",
      content: "User model handles authentication for users.")
  end

  describe "#call" do
    context "with exact mode" do
      it "finds routes by exact identifier match" do
        result = described_class.call(project: project, query: "POST /api/users", mode: "exact")

        expect(result[:results].length).to eq(1)
        expect(result[:results].first[:identifier]).to eq("POST /api/users")
        expect(result[:results].first[:source]).to eq("exact")
      end

      it "falls back to trigram similarity when no exact match" do
        result = described_class.call(project: project, query: "POST /api/user", mode: "exact")

        identifiers = result[:results].map { |r| r[:identifier] }
        expect(identifiers).to include("POST /api/users")
      end

      it "returns empty when no match at all" do
        result = described_class.call(project: project, query: "DELETE /nonexistent", mode: "exact")

        expect(result[:results]).to be_empty
      end

      it "includes project version info" do
        result = described_class.call(project: project, query: "POST /api/users", mode: "exact")

        version_info = result[:results].first[:project_version]
        expect(version_info[:commit_sha]).to eq("abc123")
      end

      it "filters by artifact_type" do
        create(:knowledge_artifact,
          project: project,
          collector_run: collector_run,
          artifact_type: "dependency",
          identifier: "POST /api/users",
          content: "something else")

        result = described_class.call(
          project: project,
          query: "POST /api/users",
          mode: "exact",
          artifact_type: "route"
        )

        expect(result[:results].map { |r| r[:artifact_type] }).to all(eq("route"))
      end

      it "returns exact_count and semantic_count in meta" do
        result = described_class.call(project: project, query: "POST /api/users", mode: "exact")

        expect(result[:meta][:exact_count]).to eq(1)
        expect(result[:meta][:semantic_count]).to eq(0)
      end

      # @spec KNOWLEDGE-010
      it "does not report degraded vector search since exact mode never runs it" do
        result = described_class.call(project: project, query: "POST /api/users", mode: "exact")

        expect(result[:meta][:vector_search_status]).to eq("not_applicable")
        expect(result[:meta][:degraded]).to be(false)
      end

      it "strips internal scoring fields from results" do
        result = described_class.call(project: project, query: "POST /api/users", mode: "exact")

        expect(result[:results].first).not_to have_key(:status)
        expect(result[:results].first).not_to have_key(:link_count)
        expect(result[:results].first).not_to have_key(:created_at)
      end

      # @spec KNOWLEDGE-CURATED-002
      it "tags derived results as not curated" do
        result = described_class.call(project: project, query: "POST /api/users", mode: "exact")

        expect(result[:results].first[:curated]).to be(false)
      end

      it "tags curated results as curated" do
        curated_artifact = create(:knowledge_artifact,
          project: project, collector_run: collector_run,
          artifact_type: "decision_record", identifier: "Use JWT for auth",
          content: "decision")
        create(:knowledge_chunk,
          knowledge_artifact: curated_artifact, project: project,
          chunk_type: "definition", content: "We chose JWT for authentication.")

        result = described_class.call(project: project, query: "Use JWT for auth", mode: "exact")

        expect(result[:results].first[:curated]).to be(true)
      end
    end

    context "with semantic mode" do
      before { get_chunk } # ensure chunk exists in DB for full-text search

      it "finds routes via full-text search" do
        result = described_class.call(project: project, query: "users route controller", mode: "semantic")

        expect(result[:results]).not_to be_empty
        expect(result[:results].first[:source]).to eq("semantic")
      end

      it "returns results with artifact info" do
        result = described_class.call(project: project, query: "lists all users", mode: "semantic")

        expect(result[:results]).not_to be_empty
        expect(result[:results].first[:artifact_type]).to eq("route")
      end

      it "returns semantic_count in meta" do
        result = described_class.call(project: project, query: "users route controller", mode: "semantic")

        expect(result[:meta][:semantic_count]).to be >= 1
        expect(result[:meta][:exact_count]).to eq(0)
      end

      # @spec KNOWLEDGE-010
      it "reports degraded vector search when Qdrant is unavailable" do
        result = described_class.call(project: project, query: "users route controller", mode: "semantic")

        expect(result[:meta][:vector_search_status]).to eq("not_configured")
        expect(result[:meta][:degraded]).to be(true)
      end
    end

    context "with hybrid mode" do
      it "merges exact and semantic results" do
        result = described_class.call(project: project, query: "POST /api/users", mode: "hybrid")

        expect(result[:results]).not_to be_empty
        expect(result[:meta][:mode]).to eq("hybrid")
      end

      it "deduplicates results across modes" do
        result = described_class.call(project: project, query: "POST /api/users", mode: "hybrid")

        chunk_ids = result[:results].map { |r| r[:chunk_id] }
        expect(chunk_ids.uniq.length).to eq(chunk_ids.length)
      end

      it "returns exact and semantic counts in meta" do
        result = described_class.call(project: project, query: "POST /api/users", mode: "hybrid")

        expect(result[:meta]).to have_key(:exact_count)
        expect(result[:meta]).to have_key(:semantic_count)
      end

      # @spec KNOWLEDGE-010
      it "reports degraded vector search when the semantic half could not contribute" do
        result = described_class.call(project: project, query: "POST /api/users", mode: "hybrid")

        expect(result[:meta][:vector_search_status]).to eq("not_configured")
        expect(result[:meta][:degraded]).to be(true)
      end

      it "does not report degraded when the vector search executes to completion" do
        allow(Knowledge::Search::Semantic).to receive(:call).and_return({ results: [], vector_search_status: "ok" })

        result = described_class.call(project: project, query: "POST /api/users", mode: "hybrid")

        expect(result[:meta][:vector_search_status]).to eq("ok")
        expect(result[:meta][:degraded]).to be(false)
      end
    end

    context "with version parameter" do
      it "passes version to hybrid search for re-ranking" do
        result = described_class.call(
          project: project,
          query: "POST /api/users",
          mode: "hybrid",
          version: "abc123"
        )

        expect(result[:results]).not_to be_empty
      end
    end

    context "with default mode" do
      it "defaults to hybrid" do
        result = described_class.call(project: project, query: "POST /api/users")

        expect(result[:meta][:mode]).to eq("hybrid")
      end
    end

    it "includes timing metadata" do
      result = described_class.call(project: project, query: "POST /api/users")

      expect(result[:meta][:took_ms]).to be_a(Integer)
      expect(result[:meta][:took_ms]).to be >= 0
    end

    it "respects limit parameter" do
      result = described_class.call(project: project, query: "api", mode: "semantic", limit: 1)

      expect(result[:results].length).to be <= 1
    end

    it "does not return stale artifacts in exact mode" do
      route_artifact.update!(status: "stale")
      route_chunk.update!(status: "stale")

      result = described_class.call(project: project, query: "POST /api/users", mode: "exact")

      expect(result[:results].map { |r| r[:identifier] }).not_to include("POST /api/users")
    end

    it "passes project search arguments to semantic search" do
      allow(Knowledge::Search::Semantic).to receive(:call).and_return({ results: [], vector_search_status: "not_configured" })

      described_class.call(
        project: project,
        query: "test",
        mode: "semantic"
      )

      expect(Knowledge::Search::Semantic).to have_received(:call).with(
        hash_including(project: project, query: "test", limit: described_class::DEFAULT_LIMIT)
      )
    end

    it "passes project search arguments to hybrid search" do
      allow(Knowledge::Search::Hybrid).to receive(:call).and_return(
        { results: [], exact_count: 0, semantic_count: 0 }
      )

      described_class.call(
        project: project,
        query: "test",
        mode: "hybrid"
      )

      expect(Knowledge::Search::Hybrid).to have_received(:call).with(
        hash_including(project: project, query: "test", limit: described_class::DEFAULT_LIMIT)
      )
    end

    it "records usage stats by artifact type when agent_run_id is provided" do
      symbol_chunk

      result = described_class.call(
        project: project,
        query: "users authentication",
        mode: "semantic",
        agent_run_id: agent_run.id
      )

      expect(result[:results].map { |row| row[:artifact_type] }).to include("route", "symbol")
      expect(KnowledgeUsageStat.where(agent_run: agent_run).order(:artifact_type).pluck(
        :artifact_type, :goal, :context_type, :artifact_count, :chunk_count
      )).to eq([
        [ "route", agent_run.goal, "search", 1, 1 ],
        [ "symbol", agent_run.goal, "search", 1, 1 ]
      ])
    end

    it "accumulates tracked search usage across repeated searches" do
      symbol_chunk

      2.times do
        described_class.call(
          project: project,
          query: "users authentication",
          mode: "semantic",
          agent_run_id: agent_run.id
        )
      end

      expect(KnowledgeUsageStat.where(agent_run: agent_run).order(:artifact_type).pluck(
        :artifact_type, :goal, :context_type, :artifact_count, :chunk_count
      )).to eq([
        [ "route", agent_run.goal, "search", 2, 2 ],
        [ "symbol", agent_run.goal, "search", 2, 2 ]
      ])
    end

    it "does not record usage stats when agent_run_id is nil" do
      symbol_chunk

      expect {
        described_class.call(project: project, query: "users authentication", mode: "semantic")
      }.not_to change(KnowledgeUsageStat, :count)
    end
  end
end
