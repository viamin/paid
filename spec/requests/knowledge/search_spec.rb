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

      it "renders the project directory page" do
        get knowledge_search_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Knowledge")
      end

      it "lists projects with their knowledge status" do
        project # ensure created
        get knowledge_search_path
        expect(response.body).to include(project.name)
      end

      it "shows artifact type counts for each project" do
        version = create(:project_version, project: project)
        run = create(:collector_run, :completed, project_version: version)
        create(:knowledge_artifact, collector_run: run, project: project,
          artifact_type: "route", identifier: "GET /test")

        get knowledge_search_path
        expect(response.body).to include("Route")
      end

      it "links to project-scoped browse and search" do
        project # ensure created
        get knowledge_search_path
        expect(response.body).to include(project_knowledge_browse_index_path(project))
        expect(response.body).to include(project_knowledge_search_path(project))
      end
    end
  end

  describe "GET /projects/:project_id/knowledge/search" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get project_knowledge_search_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the project-scoped search page" do
        get project_knowledge_search_path(project)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Search Knowledge")
        expect(response.body).to include(project.name)
      end

      it "shows the active artifact type filter and clear control" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)

        get project_knowledge_search_path(project), params: { type: "route", q: "users", mode: "hybrid" }

        doc = Nokogiri::HTML(response.body)
        clear_filter_link = doc.css("a").find { |link| link.text.include?("Clear filter") }

        expect(doc.text).to include("Filtering to")
        expect(doc.text).to include("Routes")
        expect(clear_filter_link["href"]).to eq(project_knowledge_search_path(project, q: "users", mode: "exact"))
      end

      it "shows a warning when no knowledge embedding provider is available" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
        get project_knowledge_search_path(project)
        expect(response.body).to include("No configured knowledge embedding provider is available")
      end

      it "shows the user key name and manage link when the current user owns the API key" do
        create(:provider_api_key, user: user, name: "My OpenAI Key", api_service_type: "openai", api_key: "sk-test-key")
        project.update!(created_by: user)
        get project_knowledge_search_path(project)
        expect(response.body).not_to include("No configured knowledge embedding provider is available")
        expect(response.body).to include("My OpenAI Key")
        expect(response.body).to include("Manage your API keys")
      end

      it "shows view link when the API key belongs to another user" do
        other_user = create(:user, account: account)
        create(:provider_api_key, user: other_user, name: "Other Key", api_service_type: "openai", api_key: "sk-other")
        project.update!(created_by: other_user)
        get project_knowledge_search_path(project)
        expect(response.body).to include("View your API keys")
      end

      it "shows platform key status with no manage link when a platform OpenAI API key is set" do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("sk-platform-key")
        allow(ENV).to receive(:fetch).with("OPENAI_API_KEY", anything).and_return("sk-platform-key")
        get project_knowledge_search_path(project)
        expect(response.body).not_to include("No configured knowledge embedding provider is available")
        expect(response.body).to include("platform-provided")
        expect(response.body).not_to include("Manage your API keys")
        expect(response.body).not_to include("View your API keys")
      end

      it "disables Hybrid and Semantic mode options when no API key is available" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
        get project_knowledge_search_path(project)

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
        get project_knowledge_search_path(project)

        doc = Nokogiri::HTML(response.body)
        hybrid_option = doc.at_css('option[value="hybrid"]')
        semantic_option = doc.at_css('option[value="semantic"]')

        expect(hybrid_option["disabled"]).to be_nil
        expect(semantic_option["disabled"]).to be_nil
      end

      it "shows embedding model info when mode is hybrid or semantic" do
        owner = project.effective_owner
        create(:provider_api_key, user: owner, api_service_type: "openai", api_key: "sk-test-key")
        get project_knowledge_search_path(project, mode: "hybrid")
        expect(response.body).to include("Embedding model")

        get project_knowledge_search_path(project, mode: "semantic")
        expect(response.body).to include("Embedding model")
      end

      it "hides embedding model info when mode is exact even with a key available" do
        owner = project.effective_owner
        create(:provider_api_key, user: owner, api_service_type: "openai", api_key: "sk-test-key")
        get project_knowledge_search_path(project, mode: "exact")
        expect(response.body).not_to include("Embedding model")
      end
    end
  end

  describe "GET /knowledge/search/results" do
    before { sign_in user }

    it "requires a project" do
      get knowledge_search_results_path, params: { q: "test" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Please select a project to search")
    end

    it "requires a query" do
      get knowledge_search_results_path, params: { project_id: project.id }
      follow_redirect!
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /projects/:project_id/knowledge/search/results" do
    before { sign_in user }

    it "requires a query" do
      get project_knowledge_search_results_path(project)
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
        get project_knowledge_search_results_path(project), params: { q: "test", mode: "exact" }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("GET /api/test")
        expect(response.body).to include("route")
      end

      it "routes project search through Knowledge::Search without passing raw API keys" do
        owner = project.effective_owner
        create(:provider_api_key, user: owner, api_service_type: "openai", api_key: "sk-test-search")

        allow(Knowledge::Search).to receive(:call).and_return({ results: [], meta: { mode: "hybrid", total: 0, took_ms: 0, exact_count: 0, semantic_count: 0 } })

        get project_knowledge_search_results_path(project), params: { q: "test" }

        expect(Knowledge::Search).to have_received(:call).with(
          hash_including(project: project, query: "test", mode: "hybrid", limit: 20)
        )
      end

      it "keeps hybrid search enabled when only a platform OpenAI credential is available" do
        owner = project.effective_owner
        owner.settings.update!(kb_embedding_runner: "openai", kb_embedding_fallback_runners: [])
        allow(Rails.application.credentials).to receive(:dig).with(:llm, :openai_api_key).and_return("sk-platform")
        allow(Knowledge::Search).to receive(:call).and_return({ results: [], meta: { mode: "hybrid", total: 0, took_ms: 0, exact_count: 0, semantic_count: 0 } })

        get project_knowledge_search_results_path(project), params: { q: "test", mode: "hybrid" }

        expect(Knowledge::Search).to have_received(:call).with(
          hash_including(project: project, query: "test", mode: "hybrid", limit: 20)
        )
        expect(response.body).not_to include("(mode: exact)")
      end
    end

    context "when no API key is available" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
      end

      it "coerces mode=hybrid to exact when no API key is available" do
        get project_knowledge_search_results_path(project), params: { q: "test", mode: "hybrid" }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("(mode: exact)")
      end

      it "coerces mode=semantic to exact when no API key is available" do
        get project_knowledge_search_results_path(project), params: { q: "test", mode: "semantic" }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("(mode: exact)")
      end
    end
  end

  describe "GET /projects/:project_id/knowledge/browse/:id" do
    let(:version) { create(:project_version, project: project) }
    let(:run) { create(:collector_run, :completed, project_version: version) }

    before do
      sign_in user
      51.times do |index|
        artifact = create(:knowledge_artifact,
          collector_run: run,
          project: project,
          artifact_type: "route",
          identifier: format("GET /api/%03d", index))
        create(:knowledge_chunk, knowledge_artifact: artifact, project: project, chunk_type: "definition", content: "chunk #{index}")
      end
    end

    it "paginates artifact listings instead of truncating them" do
      get project_knowledge_browse_path(project, "route")

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      next_link = doc.css("a").find { |link| link.text.include?("Next") }

      expect(doc.text).to include("Showing")
      expect(doc.text).to include("Page")
      expect(doc.css("tbody tr").size).to eq(50)
      expect(next_link["href"]).to eq(project_knowledge_browse_path(project, "route", page: 2))
      expect(doc.text).to include("GET /api/000")
      expect(doc.text).not_to include("GET /api/050")
    end

    it "shows later records on subsequent pages" do
      get project_knowledge_browse_path(project, "route"), params: { page: 2 }

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      previous_link = doc.css("a").find { |link| link.text.include?("Previous") }

      expect(doc.css("tbody tr").size).to eq(1)
      expect(doc.text).to include("GET /api/050")
      expect(doc.text).not_to include("GET /api/000")
      expect(previous_link["href"]).to eq(project_knowledge_browse_path(project, "route", page: 1))
    end
  end
end
