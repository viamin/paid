# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-009
RSpec.describe Api::KnowledgeMapController, type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }

  before { sign_in user }

  describe "GET /api/knowledge/map" do
    it "returns a knowledge map for the project" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      create(:knowledge_artifact, project: project, collector_run: collector_run, artifact_type: "route")

      get "/api/knowledge/map", params: { project_id: project.id }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["project_id"]).to eq(project.id)
      expect(body["artifact_counts"]).to eq("route" => { "active" => 1, "stale" => 0 })
    end

    it "returns 404 for unknown project" do
      get "/api/knowledge/map", params: { project_id: 0 }

      expect(response).to have_http_status(:not_found)
    end

    it "returns 401 JSON for unauthenticated requests" do
      sign_out user
      get "/api/knowledge/map", params: { project_id: project.id }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]).to eq("Unauthorized")
    end

    it "returns 403 JSON for other accounts' projects" do
      other_account = create(:account)
      other_token = create(:github_token, account: other_account)
      other_project = create(:project, account: other_account, github_token: other_token)

      get "/api/knowledge/map", params: { project_id: other_project.id }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("Forbidden")
    end
  end
end
