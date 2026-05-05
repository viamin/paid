# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::Proxy::KnowledgeSearch" do
  include_context "without qdrant vector search"

  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, project_version: project_version, collector_type: "symbols") }
  let(:agent_run) { create(:agent_run, :running, project: project) }
  let(:headers) do
    {
      "X-Agent-Run-Id" => agent_run.id.to_s,
      "X-Proxy-Token" => agent_run.proxy_token
    }
  end
  let(:chat_session) { create(:chat_session, account: project.account, project: nil) }

  describe "GET /api/proxy/knowledge/search" do
    it "returns project-scoped knowledge results for an authenticated agent run" do
      create_chunk(identifier: "Hunt#last_active", content: "Hunt last active uses prey updated timestamp")

      get "/api/proxy/knowledge/search", params: { q: "last active" }, headers: headers

      expect(response).to have_http_status(:ok)
      result = response.parsed_body.fetch("results").first
      expect(result).to include(
        "identifier" => "Hunt#last_active",
        "artifact_type" => "symbol",
        "scope_path" => "app/models/hunt.rb"
      )
      expect(result.fetch("content")).to include("prey updated timestamp")
    end

    it "defaults to five results" do
      6.times { |index| create_chunk(identifier: "Result #{index}", content: "sortable dashboard column #{index}") }

      get "/api/proxy/knowledge/search", params: { q: "sortable dashboard column" }, headers: headers

      expect(response.parsed_body.fetch("results").size).to eq(5)
    end

    it "caps requested limits at ten results" do
      12.times { |index| create_chunk(identifier: "Result #{index}", content: "sortable dashboard column #{index}") }

      get "/api/proxy/knowledge/search", params: { q: "sortable dashboard column", limit: 50 }, headers: headers

      expect(response.parsed_body.fetch("results").size).to eq(10)
    end

    it "truncates result content" do
      create_chunk(content: "searchable " + ("x" * 800))

      get "/api/proxy/knowledge/search", params: { q: "searchable" }, headers: headers

      content = response.parsed_body.fetch("results").first.fetch("content")
      expect(content.length).to eq(500)
      expect(content).to end_with("...")
    end

    it "filters by artifact type" do
      create_chunk(identifier: "POST /hunts", artifact_type: "route", content: "hunts dashboard route")
      create_chunk(identifier: "HuntDashboard", artifact_type: "symbol", content: "hunts dashboard symbol")

      get "/api/proxy/knowledge/search", params: { q: "hunts dashboard", type: "route" }, headers: headers

      identifiers = response.parsed_body.fetch("results").map { |result| result.fetch("identifier") }
      expect(identifiers).to eq([ "POST /hunts" ])
    end

    it "routes semantic search through Knowledge::Search without exposing provider credentials" do
      owner = project.effective_owner
      owner.settings.update!(kb_embedding_provider: "openrouter", kb_embedding_fallback_providers: [ "openai" ])
      create(:provider_api_key, user: owner, api_service_type: "openrouter", api_key: "sk-test-api")

      allow(Knowledge::Search).to receive(:call).and_return({ results: [] })

      get "/api/proxy/knowledge/search", params: { q: "project docs" }, headers: headers

      expect(Knowledge::Search).to have_received(:call).with(hash_including(
        project: project,
        query: "project docs",
        mode: "semantic"
      ))
    end

    it "returns 429 when the agent run exceeds the search limit" do
      allow(Rails.cache).to receive(:increment)
        .and_return(Api::Proxy::KnowledgeSearchController::RATE_LIMIT_MAX_REQUESTS + 1)

      get "/api/proxy/knowledge/search", params: { q: "last active" }, headers: headers

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body.fetch("error")).to eq("Knowledge search rate limit exceeded")
    end

    it "rejects requests without a valid container token" do
      get "/api/proxy/knowledge/search", params: { q: "last active" }, headers: {
        "X-Agent-Run-Id" => agent_run.id.to_s,
        "X-Proxy-Token" => "invalid"
      }

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 422 for a projectless chat session" do
      get "/api/proxy/knowledge/search", params: { q: "last active" }, headers: {
        "X-Chat-Session-Id" => chat_session.id.to_s,
        "X-Proxy-Token" => chat_session.proxy_token
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("error" => "No project associated with authenticated session")
    end
  end

  def create_chunk(identifier: "Hunt#last_active", artifact_type: "symbol", content:)
    artifact = create(:knowledge_artifact,
      project: project,
      collector_run: collector_run,
      artifact_type: artifact_type,
      identifier: identifier,
      scope_path: "app/models/hunt.rb")

    create(:knowledge_chunk,
      knowledge_artifact: artifact,
      project: project,
      content: content)
  end
end
