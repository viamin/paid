# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Search::Exact do
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
      scope_path: "config/routes.rb",
      metadata: { line: 4, start_line: 4, end_line: 9 })
  end

  let!(:route_chunk) do
    create(:knowledge_chunk,
      knowledge_artifact: route_artifact,
      project: project,
      chunk_type: "definition",
      content: "Route: POST /api/users\nController: api/users#create")
  end

  describe "#call" do
    it "finds artifacts by exact identifier match" do
      results = described_class.call(project: project, query: "POST /api/users")

      expect(results.length).to eq(1)
      expect(results.first[:identifier]).to eq("POST /api/users")
      expect(results.first[:source]).to eq("exact")
    end

    it "falls back to trigram similarity when no exact match" do
      results = described_class.call(project: project, query: "POST /api/user")

      identifiers = results.map { |r| r[:identifier] }
      expect(identifiers).to include("POST /api/users")
    end

    it "does not include trigram matches when an exact identifier exists" do
      fuzzy_artifact = create(:knowledge_artifact,
        project: project,
        collector_run: collector_run,
        artifact_type: "route",
        identifier: "POST /api/user",
        content: "POST /api/user -> api/users#create",
        scope_path: "config/routes.rb")
      create(:knowledge_chunk,
        knowledge_artifact: fuzzy_artifact,
        project: project,
        chunk_type: "definition",
        content: "Route: POST /api/user\nController: api/users#create")

      results = described_class.call(project: project, query: "POST /api/users")

      expect(results.map { |result| result[:identifier] }).to eq([ "POST /api/users" ])
    end

    it "returns empty when no match at all" do
      results = described_class.call(project: project, query: "DELETE /nonexistent")

      expect(results).to be_empty
    end

    it "includes project version info" do
      results = described_class.call(project: project, query: "POST /api/users")

      version_info = results.first[:project_version]
      expect(version_info[:commit_sha]).to eq("abc123")
    end

    it "includes scope_tags" do
      results = described_class.call(project: project, query: "POST /api/users")

      expect(results.first).to have_key(:scope_tags)
      expect(results.first).to include(start_line: 4, end_line: 9)
    end

    it "includes internal scoring fields" do
      results = described_class.call(project: project, query: "POST /api/users")

      expect(results.first).to have_key(:status)
      expect(results.first).to have_key(:link_count)
      expect(results.first).to have_key(:created_at)
    end

    # @spec KNOWLEDGE-URI-003
    it "includes stable knowledge uris for the chunk and its artifact" do
      results = described_class.call(project: project, query: "POST /api/users")

      expect(results.first[:uri]).to eq(route_chunk.knowledge_uri)
      expect(results.first[:artifact_uri]).to eq(route_artifact.knowledge_uri)
    end

    it "filters by artifact_type" do
      create(:knowledge_artifact,
        project: project,
        collector_run: collector_run,
        artifact_type: "dependency",
        identifier: "POST /api/users",
        content: "something else")

      results = described_class.call(
        project: project,
        query: "POST /api/users",
        artifact_type: "route"
      )

      expect(results.map { |r| r[:artifact_type] }).to all(eq("route"))
    end

    it "does not return stale artifacts" do
      route_artifact.update!(status: "stale")
      route_chunk.update!(status: "stale")

      results = described_class.call(project: project, query: "POST /api/users")

      expect(results).to be_empty
    end

    it "respects limit" do
      results = described_class.call(project: project, query: "POST /api/users", limit: 0)

      expect(results).to be_empty
    end

    # @spec KNOWLEDGE-003
    it "limits ordered chunks before aggregating their link counts" do
      chunks = bounded_chunks_with_links
      results, queries = capture_sql { described_class.call(project: project, query: "GET /bounded", limit: 5) }

      expect(results.map { |result| result[:chunk_id] }).to eq(chunks.first(5).map(&:id))
      expect(results.map { |result| result[:link_count] }).to all(eq(2))
      expect(queries.grep(/\ASELECT "knowledge_links"\.\*/i)).to be_empty
      expect(queries.join(" ")).to include("COUNT(*)")
    end
  end

  def capture_sql
    queries = []
    subscriber = ->(*args) { queries << ActiveSupport::Notifications::Event.new(*args).payload[:sql] }

    result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    [ result, queries ]
  end

  def bounded_chunks_with_links
    artifact = create(:knowledge_artifact,
      project: project, collector_run: collector_run, artifact_type: "route",
      identifier: "GET /bounded", content: "bounded route")
    chunks = create_list(:knowledge_chunk, 10,
      knowledge_artifact: artifact, project: project, chunk_type: "context", content: "bounded route context")

    chunks.each_with_index do |chunk, index|
      chunk.update!(sequence: index)
      create(:knowledge_link, source_chunk: chunk, target_chunk: route_chunk)
      create(:knowledge_link, source_chunk: route_chunk, target_chunk: chunk)
    end
    chunks
  end
end
