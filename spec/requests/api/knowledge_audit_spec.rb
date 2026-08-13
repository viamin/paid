# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::KnowledgeAudit" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }

  before do
    sign_in user
  end

  describe "GET /api/knowledge/audit" do
    it "returns audit events for a project" do
      create(:knowledge_audit_event, project: project, event_type: "artifact_created")
      create(:knowledge_audit_event, project: project, event_type: "artifact_staled")

      get "/api/knowledge/audit", params: { project_id: project.id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["events"].size).to eq(2)
      expect(body["pagination"]["count"]).to eq(2)
    end

    it "filters by event_type" do
      create(:knowledge_audit_event, project: project, event_type: "artifact_created")
      create(:knowledge_audit_event, project: project, event_type: "chunk_embedded")

      get "/api/knowledge/audit", params: { project_id: project.id, event_type: "artifact_created" }

      body = JSON.parse(response.body)
      expect(body["events"].size).to eq(1)
      expect(body["events"].first["event_type"]).to eq("artifact_created")
    end

    it "filters by target_type and target_id" do
      create(:knowledge_audit_event, project: project, target_type: "KnowledgeArtifact", target_id: "1")
      create(:knowledge_audit_event, project: project, target_type: "KnowledgeArtifact", target_id: "2")

      get "/api/knowledge/audit", params: {
        project_id: project.id,
        target_type: "KnowledgeArtifact",
        target_id: "1"
      }

      body = JSON.parse(response.body)
      expect(body["events"].size).to eq(1)
      expect(body["events"].first["target_id"]).to eq("1")
    end

    it "filters by since date" do
      create(:knowledge_audit_event, project: project, event_type: "artifact_created")

      travel_to 2.days.from_now do
        create(:knowledge_audit_event, project: project, event_type: "collection_rebuilt")
      end

      get "/api/knowledge/audit", params: {
        project_id: project.id,
        since: 1.day.from_now.iso8601
      }

      body = JSON.parse(response.body)
      expect(body["events"].size).to eq(1)
      expect(body["events"].first["event_type"]).to eq("collection_rebuilt")
    end

    it "filters by before date" do
      create(:knowledge_audit_event, project: project, event_type: "artifact_created")

      travel_to 2.days.from_now do
        create(:knowledge_audit_event, project: project, event_type: "collection_rebuilt")
      end

      get "/api/knowledge/audit", params: {
        project_id: project.id,
        before: 1.day.from_now.iso8601
      }

      body = JSON.parse(response.body)
      expect(body["events"].size).to eq(1)
      expect(body["events"].first["event_type"]).to eq("artifact_created")
    end

    it "returns 400 for invalid since timestamp" do
      get "/api/knowledge/audit", params: { project_id: project.id, since: "not-a-date" }

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Invalid since timestamp")
    end

    it "returns 400 for invalid before timestamp" do
      get "/api/knowledge/audit", params: { project_id: project.id, before: "not-a-date" }

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Invalid before timestamp")
    end

    it "returns events in descending order" do
      create(:knowledge_audit_event, project: project, event_type: "artifact_created")

      travel_to 1.hour.from_now do
        create(:knowledge_audit_event, project: project, event_type: "artifact_staled")
      end

      get "/api/knowledge/audit", params: { project_id: project.id }

      body = JSON.parse(response.body)
      expect(body["events"].first["event_type"]).to eq("artifact_staled")
      expect(body["events"].last["event_type"]).to eq("artifact_created")
    end

    it "paginates results" do
      3.times { create(:knowledge_audit_event, project: project) }

      get "/api/knowledge/audit", params: { project_id: project.id, limit: 2 }

      body = JSON.parse(response.body)
      expect(body["events"].size).to eq(2)
      expect(body["pagination"]["pages"]).to eq(2)
      expect(body["pagination"]["count"]).to eq(3)
    end

    it "returns 404 for unknown project" do
      get "/api/knowledge/audit", params: { project_id: 0 }

      expect(response).to have_http_status(:not_found)
    end

    it "requires project_id" do
      get "/api/knowledge/audit"

      expect(response).to have_http_status(:not_found)
    end

    it "returns 400 when only target_type is provided without target_id" do
      get "/api/knowledge/audit", params: { project_id: project.id, target_type: "KnowledgeArtifact" }

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Both target_type and target_id are required together")
    end

    it "returns 400 when only target_id is provided without target_type" do
      get "/api/knowledge/audit", params: { project_id: project.id, target_id: "1" }

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Both target_type and target_id are required together")
    end

    it "returns 400 for non-numeric limit" do
      get "/api/knowledge/audit", params: { project_id: project.id, limit: "abc" }

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("limit must be a positive integer")
    end

    it "returns 400 for limit of 0" do
      get "/api/knowledge/audit", params: { project_id: project.id, limit: 0 }

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("limit must be a positive integer")
    end

    it "includes all event fields in response" do
      event = create(:knowledge_audit_event,
        project: project,
        event_type: "artifact_created",
        actor_type: "collector",
        actor_id: "run_1",
        target_type: "KnowledgeArtifact",
        target_id: "99",
        details: { key: "value" }
      )

      get "/api/knowledge/audit", params: { project_id: project.id }

      body = JSON.parse(response.body)
      serialized = body["events"].first
      expect(serialized["id"]).to eq(event.id)
      expect(serialized["event_type"]).to eq("artifact_created")
      expect(serialized["actor_type"]).to eq("collector")
      expect(serialized["actor_id"]).to eq("run_1")
      expect(serialized["target_type"]).to eq("KnowledgeArtifact")
      expect(serialized["target_id"]).to eq("99")
      expect(serialized["details"]).to eq({ "key" => "value" })
      expect(serialized["created_at"]).to be_present
    end
  end
end
