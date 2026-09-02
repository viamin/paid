# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-LINT-001
RSpec.describe "Knowledge::QualityController", type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }

  before { sign_in user }

  describe "GET /projects/:project_id/knowledge/quality" do
    it "renders the quality report page" do
      project_version = create(:project_version, project: project)
      create(:collector_run, :failed, project_version: project_version, collector_type: "schema",
        error_message: "boom")

      get "/projects/#{project.id}/knowledge/quality"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Knowledge Quality")
      expect(response.body).to include("failed_collector")
    end

    it "redirects unauthenticated users" do
      sign_out user
      get "/projects/#{project.id}/knowledge/quality"

      expect(response).to have_http_status(:redirect)
    end
  end
end
