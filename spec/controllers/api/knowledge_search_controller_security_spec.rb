# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::KnowledgeSearchController, type: :request do
  include_context "without qdrant vector search"

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }

  describe "authentication" do
    it "returns redirect for unauthenticated requests" do
      get "/api/knowledge/search", params: { project_id: project.id, q: "test" }

      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "authorization" do
    before { sign_in user }

    it "allows access to own account's projects" do
      get "/api/knowledge/search", params: { project_id: project.id, q: "test", mode: "exact" }

      expect(response).to have_http_status(:ok)
    end

    it "denies access to other accounts' projects" do
      other_account = create(:account)
      other_token = create(:github_token, account: other_account)
      other_project = create(:project, account: other_account, github_token: other_token)

      get "/api/knowledge/search", params: { project_id: other_project.id, q: "test" }

      expect(response).to redirect_to(root_path)
    end
  end
end
