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

      it "shows a warning when no OpenAI API key is configured" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
        get knowledge_search_path, params: { project_id: project.id }
        expect(response.body).to include("No OpenAI API key configured")
      end

      it "shows the user key name and manage link when the current user owns the API key" do
        create(:provider_api_key, user: user, name: "My OpenAI Key", api_service_type: "openai", api_key: "sk-test-key")
        project.update!(created_by: user)
        get knowledge_search_path, params: { project_id: project.id }
        expect(response.body).not_to include("No OpenAI API key configured")
        expect(response.body).to include("My OpenAI Key")
        expect(response.body).to include("Manage your API keys")
      end

      it "shows view link when the API key belongs to another user" do
        other_user = create(:user, account: account)
        create(:provider_api_key, user: other_user, name: "Other Key", api_service_type: "openai", api_key: "sk-other")
        project.update!(created_by: other_user)
        get knowledge_search_path, params: { project_id: project.id }
        expect(response.body).to include("View your API keys")
      end

      it "shows platform key status with no manage link when a platform OpenAI API key is set" do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("sk-platform-key")
        allow(ENV).to receive(:fetch).with("OPENAI_API_KEY", anything).and_return("sk-platform-key")
        get knowledge_search_path, params: { project_id: project.id }
        expect(response.body).not_to include("No OpenAI API key configured")
        expect(response.body).to include("platform-provided")
        expect(response.body).not_to include("Manage your API keys")
        expect(response.body).not_to include("View your API keys")
      end

      it "disables Hybrid and Semantic mode options when no API key is available" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
        get knowledge_search_path, params: { project_id: project.id }

        doc = Nokogiri::HTML(response.body)
        hybrid_option = doc.at_css('option[value="hybrid"]')
        semantic_option = doc.at_css('option[value="semantic"]')
        exact_option = doc.at_css('option[value="exact"]')

        expect(hybrid_option["disabled"]).to eq("disabled")
        expect(semantic_option["disabled"]).to eq("disabled")
        expect(exact_option["disabled"]).to be_nil
      end

      it "enables all mode options when an API key is available" do
        owner = project.effective_owner
        create(:provider_api_key, user: owner, api_service_type: "openai", api_key: "sk-test-key")
        get knowledge_search_path, params: { project_id: project.id }

        doc = Nokogiri::HTML(response.body)
        hybrid_option = doc.at_css('option[value="hybrid"]')
        semantic_option = doc.at_css('option[value="semantic"]')

        expect(hybrid_option["disabled"]).to be_nil
        expect(semantic_option["disabled"]).to be_nil
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

      it "passes the project's OpenAI API key to Knowledge::Search" do
        owner = project.effective_owner
        api_key = create(:provider_api_key, user: owner, api_service_type: "openai", api_key: "sk-test-search")

        allow(Knowledge::Search).to receive(:call).and_return({ results: [], meta: { mode: "hybrid", total: 0, took_ms: 0, exact_count: 0, semantic_count: 0 } })

        get knowledge_search_results_path, params: { project_id: project.id, q: "test" }

        expect(Knowledge::Search).to have_received(:call).with(
          hash_including(api_key: api_key.api_key)
        )
      end
    end

    context "when no API key is available" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
      end

      it "coerces mode=hybrid to exact when no API key is available" do
        get knowledge_search_results_path, params: { project_id: project.id, q: "test", mode: "hybrid" }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("(mode: exact)")
      end

      it "coerces mode=semantic to exact when no API key is available" do
        get knowledge_search_results_path, params: { project_id: project.id, q: "test", mode: "semantic" }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("(mode: exact)")
      end
    end
  end
end
