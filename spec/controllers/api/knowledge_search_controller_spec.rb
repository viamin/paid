# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::KnowledgeSearchController, type: :request do
  include_context "without qdrant vector search"

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }
  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, project_version: project_version, collector_type: "routes") }

  let!(:artifact) do
    create(:knowledge_artifact,
      project: project,
      collector_run: collector_run,
      artifact_type: "route",
      identifier: "POST /api/users",
      content: "POST /api/users → api/users#create",
      scope_path: "config/routes.rb")
  end

  let(:chunk) do
    create(:knowledge_chunk,
      knowledge_artifact: artifact,
      project: project,
      chunk_type: "definition",
      content: "Route: POST /api/users\nController: api/users#create")
  end

  before { sign_in user }

  describe "GET /api/knowledge/search" do
    before { chunk } # ensure chunk exists in DB

    it "returns search results" do
      get "/api/knowledge/search", params: { project_id: project.id, q: "POST /api/users", mode: "exact" }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["results"]).not_to be_empty
      expect(body["results"].first["identifier"]).to eq("POST /api/users")
    end

    it "returns meta information" do
      get "/api/knowledge/search", params: { project_id: project.id, q: "POST /api/users" }

      body = response.parsed_body
      expect(body["meta"]).to include("mode", "total", "took_ms")
    end

    it "supports mode parameter" do
      get "/api/knowledge/search", params: { project_id: project.id, q: "users", mode: "semantic" }

      body = response.parsed_body
      expect(body["meta"]["mode"]).to eq("semantic")
    end

    it "supports type filter" do
      get "/api/knowledge/search", params: {
        project_id: project.id, q: "POST /api/users", mode: "exact", type: "route"
      }

      expect(response).to have_http_status(:ok)
    end

    it "returns 404 for unknown project" do
      get "/api/knowledge/search", params: { project_id: 0, q: "test" }

      expect(response).to have_http_status(:not_found)
    end

    it "returns 401 JSON for unauthenticated requests" do
      sign_out user
      get "/api/knowledge/search", params: { project_id: project.id, q: "test" }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to eq("Unauthorized")
    end

    it "returns 403 JSON for other accounts' projects" do
      other_account = create(:account)
      other_token = create(:github_token, account: other_account)
      other_project = create(:project, account: other_account, github_token: other_token)

      get "/api/knowledge/search", params: { project_id: other_project.id, q: "test" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("Forbidden")
    end

    context "when rate limit is exceeded" do
      it "returns 429 JSON when rate limit is exceeded" do
        limit = described_class::RATE_LIMIT_MAX_REQUESTS

        # Stub the cache store increment to simulate exceeding the rate limit.
        # The store reference is captured at class load time (NullStore in test),
        # so we stub the specific store instance to return a count above the limit.
        store = described_class.cache_store
        allow(store).to receive(:increment).and_return(limit + 1)

        get "/api/knowledge/search", params: { project_id: project.id, q: "test", mode: "exact" }

        expect(response).to have_http_status(:too_many_requests)
        expect(response.parsed_body["error"]).to eq("Rate limit exceeded")
      end
    end
  end
end
