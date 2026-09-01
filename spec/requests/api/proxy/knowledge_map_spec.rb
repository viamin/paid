# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-009
RSpec.describe "Api::Proxy::KnowledgeMap" do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :running, project: project) }
  let(:headers) do
    {
      "X-Agent-Run-Id" => agent_run.id.to_s,
      "X-Proxy-Token" => agent_run.proxy_token
    }
  end

  describe "GET /api/proxy/knowledge/map" do
    it "returns the project's knowledge map for an authenticated agent run" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      create(:knowledge_artifact, project: project, collector_run: collector_run, artifact_type: "route")

      get "/api/proxy/knowledge/map", headers: headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["project_id"]).to eq(project.id)
      expect(body["artifact_counts"]).to eq("route" => { "active" => 1, "stale" => 0 })
    end

    it "rejects requests without a valid container token" do
      get "/api/proxy/knowledge/map", headers: {
        "X-Agent-Run-Id" => agent_run.id.to_s,
        "X-Proxy-Token" => "invalid"
      }

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 422 for a projectless chat session" do
      chat_session = create(:chat_session, account: project.account, project: nil)

      get "/api/proxy/knowledge/map", headers: {
        "X-Chat-Session-Id" => chat_session.id.to_s,
        "X-Proxy-Token" => chat_session.proxy_token
      }

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
