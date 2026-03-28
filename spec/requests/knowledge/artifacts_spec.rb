# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Knowledge::Artifacts" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }
  let(:version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, :completed, project_version: version) }
  let(:artifact) do
    create(:knowledge_artifact, collector_run: collector_run, project: project,
      artifact_type: "route", identifier: "GET /api/users")
  end

  describe "GET /knowledge_artifacts/:id" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get knowledge_artifact_path(artifact)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the artifact detail page" do
        get knowledge_artifact_path(artifact)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("GET /api/users")
        expect(response.body).to include("route")
      end

      it "shows provenance information" do
        get knowledge_artifact_path(artifact)
        expect(response.body).to include(project.name)
        expect(response.body).to include(version.commit_sha.first(7))
        expect(response.body).to include(version.branch)
      end

      it "shows chunks" do
        create(:knowledge_chunk, knowledge_artifact: artifact, project: project,
          content: "Test chunk content")
        get knowledge_artifact_path(artifact)
        expect(response.body).to include("Test chunk content")
        expect(response.body).to include("Chunks (1)")
      end
    end
  end
end
