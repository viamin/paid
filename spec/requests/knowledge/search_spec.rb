# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Knowledge::Search" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }

  describe "GET /knowledge/search" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get knowledge_search_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the search page" do
        get knowledge_search_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Knowledge Search")
      end

      it "lists projects in the selector" do
        project # ensure created
        get knowledge_search_path
        expect(response.body).to include(project.name)
      end
    end
  end

  describe "GET /knowledge/search/results" do
    before { sign_in user }

    it "requires a project" do
      get knowledge_search_results_path, params: { q: "test" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Please select a project")
    end

    it "requires a query" do
      get knowledge_search_results_path, params: { project_id: project.id }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Please enter a search query")
    end

    context "with valid params" do
      let(:version) { create(:project_version, project: project) }
      let(:run) { create(:collector_run, :completed, project_version: version) }
      let(:artifact) do
        create(:knowledge_artifact, collector_run: run, project: project,
          artifact_type: "route", identifier: "GET /api/test")
      end

      before do
        create(:knowledge_chunk, knowledge_artifact: artifact, project: project,
          chunk_type: "definition", content: "Test endpoint definition")
      end

      it "returns search results including the matching artifact" do
        get knowledge_search_results_path, params: { project_id: project.id, q: "test", mode: "exact" }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("GET /api/test")
        expect(response.body).to include("route")
      end
    end
  end
end
