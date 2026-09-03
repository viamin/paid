# frozen_string_literal: true

require "rails_helper"
require "qdrant"

# @spec KNOWLEDGE-011
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
      scope_path: "config/routes.rb",
      metadata: { line: 12, start_line: 12, end_line: 18 })
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
        results = described_class.call(project: project, query: "lists all users")[:results]

        expect(results).not_to be_empty
        expect(results.first[:source]).to eq("semantic")
      end

      it "returns results with artifact info" do
        results = described_class.call(project: project, query: "users route controller")[:results]

        expect(results).not_to be_empty
        expect(results.first[:artifact_type]).to eq("route")
        expect(results.first[:identifier]).to eq("GET /api/users")
      end

      it "includes scope_tags and scoring fields" do
        results = described_class.call(project: project, query: "lists all users")[:results]

        expect(results.first).to have_key(:scope_tags)
        expect(results.first).to include(start_line: 12, end_line: 18)
        expect(results.first).to have_key(:link_count)
        expect(results.first).to have_key(:created_at)
      end

      # @spec KNOWLEDGE-URI-003
      it "includes stable knowledge uris for the chunk and its artifact" do
        results = described_class.call(project: project, query: "lists all users")[:results]

        expect(results.first[:uri]).to eq(route_artifact.knowledge_chunks.first.knowledge_uri)
        expect(results.first[:artifact_uri]).to eq(route_artifact.knowledge_uri)
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
        )[:results]

        expect(results.map { |r| r[:artifact_type] }).to all(eq("route"))
      end
    end

    context "with vector search unavailable" do
      it "still returns lexical results" do
        results = described_class.call(project: project, query: "lists all users")[:results]

        expect(results).not_to be_empty
      end

      it "reports vector_search_status as not_configured" do
        output = described_class.call(project: project, query: "lists all users")

        expect(output[:vector_search_status]).to eq("not_configured")
      end
    end

    context "with qdrant available but unhealthy" do
      it "reports vector_search_status as unhealthy" do
        allow(Paid).to receive_messages(qdrant_url: "http://localhost:6333", qdrant_client: double(healthy?: false))

        output = described_class.call(project: project, query: "lists all users")

        expect(output[:vector_search_status]).to eq("unhealthy")
      end
    end

    context "with qdrant healthy but the project has no embedded chunks" do
      it "reports vector_search_status as no_embeddings without generating a query embedding" do
        allow(Paid).to receive_messages(qdrant_url: "http://localhost:6333", qdrant_client: double(healthy?: true))
        allow(Knowledge::Embeddings::ProxyGenerator).to receive(:new)

        output = described_class.call(project: project, query: "lists all users")

        expect(output[:vector_search_status]).to eq("no_embeddings")
        expect(Knowledge::Embeddings::ProxyGenerator).not_to have_received(:new)
      end
    end

    context "with embedded chunks but the qdrant collection is empty" do
      # PG tracks `embedding_model` on chunks, but the Qdrant index can be
      # out of sync — e.g. after `rebuild_schema!` drops and recreates the
      # collection without re-upserting points. Without the index check the
      # search would proceed, return zero hits, and report ok (silent
      # lexical-only fallback).
      # "No active points" covers both a never-populated/rebuilt collection
      # and one whose points were all flipped to `stale` in Postgres without
      # being deleted from Qdrant — the probe gates on the same state either
      # way.
      it "reports vector_search_status as no_index without generating a query embedding" do
        create(:knowledge_chunk, :embedded, knowledge_artifact: route_artifact, project: project)
        stub_empty_qdrant_collection(project)
        allow(Knowledge::Embeddings::ProxyGenerator).to receive(:new)

        output = described_class.call(project: project, query: "lists all users")

        expect(output[:vector_search_status]).to eq("no_index")
        expect(Knowledge::Embeddings::ProxyGenerator).not_to have_received(:new)
      end

      it "reports vector_search_status as no_index when the qdrant collection is missing" do
        create(:knowledge_chunk, :embedded, knowledge_artifact: route_artifact, project: project)
        qdrant_client = stub_populated_qdrant_collection(project)
        allow(qdrant_client.points).to receive(:scroll)
          .and_raise(Qdrant::Error.new("Not found: collection 'foo' doesn't exist"))
        allow(Knowledge::Embeddings::ProxyGenerator).to receive(:new)

        output = described_class.call(project: project, query: "lists all users")

        expect(output[:vector_search_status]).to eq("no_index")
        expect(Knowledge::Embeddings::ProxyGenerator).not_to have_received(:new)
      end
    end

    context "with embedded chunks but embedding generation fails" do
      it "reports vector_search_status as embedding_failed" do
        create(:knowledge_chunk, :embedded, knowledge_artifact: route_artifact, project: project)
        stub_populated_qdrant_collection(project)
        proxy_generator = instance_double(Knowledge::Embeddings::ProxyGenerator, call: [], close: true)
        allow(Knowledge::Embeddings::ProxyGenerator).to receive(:new).and_return(proxy_generator)

        output = described_class.call(project: project, query: "test")

        expect(output[:vector_search_status]).to eq("embedding_failed")
      end
    end

    context "with vector search raising an error" do
      it "reports vector_search_status as error and still returns lexical results" do
        create(:knowledge_chunk, :embedded, knowledge_artifact: route_artifact, project: project)
        qdrant_client = stub_populated_qdrant_collection(project)
        embedding = Knowledge::Embeddings::Generate::Result.new(vector: [ 0.1 ], token_count: 1)
        proxy_generator = instance_double(Knowledge::Embeddings::ProxyGenerator, call: [ embedding ], close: true)
        allow(Knowledge::Embeddings::ProxyGenerator).to receive(:new).and_return(proxy_generator)
        allow(qdrant_client.points).to receive(:search).and_raise(StandardError, "boom")

        output = described_class.call(project: project, query: "lists all users")

        expect(output[:vector_search_status]).to eq("error")
        expect(output[:results]).not_to be_empty
      end
    end

    context "with query embeddings" do
      it "routes query embedding generation through the proxy-backed generator" do
        create(:knowledge_chunk, :embedded, knowledge_artifact: route_artifact, project: project)
        stub_populated_qdrant_collection(project)
        proxy_generator = instance_double(Knowledge::Embeddings::ProxyGenerator, call: [], close: true)
        allow(Knowledge::Embeddings::ProxyGenerator).to receive(:new).with(project: project, containerize: false).and_return(proxy_generator)

        described_class.call(project: project, query: "test")

        expect(proxy_generator).to have_received(:call).with(texts: [ "test" ])
        expect(proxy_generator).to have_received(:close)
      end

      it "reports vector_search_status as ok when the search executes to completion" do
        create(:knowledge_chunk, :embedded, knowledge_artifact: route_artifact, project: project)
        qdrant_client = stub_populated_qdrant_collection(project)
        embedding = Knowledge::Embeddings::Generate::Result.new(vector: [ 0.1 ], token_count: 1)
        proxy_generator = instance_double(Knowledge::Embeddings::ProxyGenerator, call: [ embedding ], close: true)
        allow(Knowledge::Embeddings::ProxyGenerator).to receive(:new).and_return(proxy_generator)
        allow(qdrant_client.points).to receive(:search).and_return({ "result" => [] })

        output = described_class.call(project: project, query: "test")

        expect(output[:vector_search_status]).to eq("ok")
      end
    end
  end

  def active_status_filter
    { must: [ { key: "status", match: { value: "active" } } ] }
  end

  # Stubs `Paid.qdrant_*` so `qdrant_healthy?` and the populated-collection
  # gate both pass through to the embedding/search steps. Returns the stubbed
  # client so tests can layer additional stubs (e.g. `points.search`) on
  # `qdrant_client.points`, which already has `scroll` stubbed here.
  def stub_populated_qdrant_collection(project)
    stub_qdrant_collection_probe(project, points: [ { "id" => "active-point" } ])
  end

  def stub_empty_qdrant_collection(project)
    stub_qdrant_collection_probe(project, points: [])
  end

  def stub_qdrant_collection_probe(project, points:)
    qdrant_client = instance_double(QdrantClient, healthy?: true)
    qdrant_points = instance_double(Qdrant::Points)
    allow(qdrant_points).to receive(:scroll)
      .with(collection_name: "account_#{project.account_id}_project_#{project.id}",
        limit: 1, filter: active_status_filter, with_payload: false)
      .and_return({ "result" => { "points" => points } })
    allow(qdrant_client).to receive(:points).and_return(qdrant_points)
    allow(Paid).to receive_messages(qdrant_url: "http://localhost:6333", qdrant_client: qdrant_client)
    qdrant_client
  end
end
