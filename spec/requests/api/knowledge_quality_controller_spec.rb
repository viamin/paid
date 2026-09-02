# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-LINT-001
RSpec.describe Api::KnowledgeQualityController, type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }

  before { sign_in user }

  describe "GET /api/knowledge/quality" do
    it "returns a knowledge quality report for the project" do
      project_version = create(:project_version, project: project)
      create(:collector_run, :failed, project_version: project_version, collector_type: "schema",
        error_message: "boom")

      get "/api/knowledge/quality", params: { project_id: project.id }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["project_id"]).to eq(project.id)
      expect(body["checks"]).to be_an(Array)
      expect(body["findings"]).to be_an(Array)
      expect(body["summary"]).to include("error", "warning", "info", "total")
    end

    it "returns 401 JSON for unauthenticated requests" do
      sign_out user
      get "/api/knowledge/quality", params: { project_id: project.id }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to eq("Unauthorized")
    end

    it "returns 404 for unknown project" do
      get "/api/knowledge/quality", params: { project_id: 0 }

      expect(response).to have_http_status(:not_found)
    end

    it "returns 403 JSON for other accounts' projects" do
      other_account = create(:account)
      other_token = create(:github_token, account: other_account)
      other_project = create(:project, account: other_account, github_token: other_token)

      get "/api/knowledge/quality", params: { project_id: other_project.id }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("Forbidden")
    end

    it "filters findings by minimum severity when requested" do
      project_version = create(:project_version, project: project)
      create(:collector_run, :failed, project_version: project_version, collector_type: "schema",
        error_message: "boom")

      get "/api/knowledge/quality", params: { project_id: project.id, min_severity: "error" }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["findings"]).not_to be_empty
      expect(body["findings"].map { |f| f["severity"] }.uniq).to eq([ "error" ])
    end

    it "recomputes summary counts to match filtered findings, not the raw report" do
      project_version = create(:project_version, project: project)
      create(:collector_run, :failed, project_version: project_version, collector_type: "schema",
        error_message: "boom")

      get "/api/knowledge/quality", params: { project_id: project.id, min_severity: "error" }

      body = response.parsed_body
      # Summary must describe the filtered findings, otherwise a CI consumer
      # aggregating from `summary` would see counts that disagree with the
      # `findings` array in the same response.
      expect(body["summary"]["total"]).to eq(body["findings"].size)
      expect(body["summary"]["info"]).to eq(0)
      expect(body["summary"]["warning"]).to eq(0)
      expect(body["summary"]["error"]).to eq(body["findings"].size)
    end

    it "returns 400 for unknown min_severity values" do
      get "/api/knowledge/quality", params: { project_id: project.id, min_severity: "critical" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("min_severity must be one of: info, warning, error")
    end

    it "returns 429 JSON when the per-user rate limit is exceeded" do
      # The rate-limit cache is captured at class load time (NullStore in
      # test), so stub the specific store instance to simulate exceeding
      # the limit without hammering the endpoint in the test.
      limit = described_class::RATE_LIMIT_MAX_REQUESTS
      store = described_class.cache_store
      allow(store).to receive(:increment).and_return(limit + 1)

      get "/api/knowledge/quality", params: { project_id: project.id }

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body["error"]).to eq("Rate limit exceeded")
    end
  end
end
