# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-009
RSpec.describe "Knowledge::Browse", type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }

  before { sign_in user }

  describe "GET /projects/:project_id/knowledge/browse" do
    it "renders collector freshness and coverage gaps alongside artifact counts" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      create(:knowledge_artifact, project: project, collector_run: collector_run, artifact_type: "route")

      get project_knowledge_browse_index_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Collector Freshness")
      expect(response.body).to include("Coverage Gaps")
    end

    # @spec KNOWLEDGE-CURATED-003
    it "separates curated artifact types from derived artifact types" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      create(:knowledge_artifact, project: project, collector_run: collector_run, artifact_type: "route")
      create(:knowledge_artifact, project: project, collector_run: collector_run, artifact_type: "decision_record")

      get project_knowledge_browse_index_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Curated Knowledge")
      expect(response.body).to include("Derived Knowledge")
    end
  end

  describe "GET /projects/:project_id/knowledge/browse/:id" do
    it "labels a curated artifact type as curated" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      create(:knowledge_artifact, project: project, collector_run: collector_run, artifact_type: "decision_record")

      get project_knowledge_browse_path(project, "decision_record")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Curated")
    end

    it "labels a derived artifact type as derived" do
      project_version = create(:project_version, project: project)
      collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
      create(:knowledge_artifact, project: project, collector_run: collector_run, artifact_type: "route")

      get project_knowledge_browse_path(project, "route")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Derived")
    end
  end
end
