# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GithubInstallations" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  before { sign_in user }

  describe "GET /github_installations" do
    it "renders the installation index" do
      create(:github_installation, account: account)

      get github_installations_path

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /github_installations/:id" do
    it "renders the installation show page" do
      installation = create(:github_installation, account: account)

      get github_installation_path(installation)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /github_installations/:id/repositories" do
    it "returns normalized repositories for the installation" do
      installation = create(
        :github_installation,
        account: account,
        accessible_repositories: [
          { "id" => 123, "full_name" => "acme/widgets", "private" => true, "default_branch" => "trunk" }
        ]
      )

      get repositories_github_installation_path(installation)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq([
        {
          "id" => 123,
          "full_name" => "acme/widgets",
          "name" => "widgets",
          "owner" => "acme",
          "default_branch" => "trunk",
          "private" => true
        }
      ])
    end

    it "filters out repositories already linked to the current account" do
      installation = create(
        :github_installation,
        account: account,
        accessible_repositories: [
          { "id" => 123, "full_name" => "acme/widgets" },
          { "id" => 456, "full_name" => "acme/gadgets" }
        ]
      )
      create(:project, account: account, created_by: user, github_id: 123)

      get repositories_github_installation_path(installation)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.map { |repo| repo.fetch("id") }).to eq([ 456 ])
    end
  end

  describe "GET /github_installations/:id/migrate" do
    it "routes to the migration form action" do
      installation = create(:github_installation, account: account)
      github_token = create(:github_token, account: account, created_by: user)
      create(:project, account: account, created_by: user, github_token: github_token)

      get migrate_project_github_installation_path(installation)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /github_installations/:id/check_access" do
    it "loads the installation and returns accessibility results" do
      installation = create(:github_installation, account: account)
      github_token = create(:github_token, account: account, created_by: user)

      allow(Github::MigrationService).to receive(:check_accessibility).and_return(
        "acme/widgets" => :accessible
      )

      post check_access_github_installation_path(installation), params: { github_token_id: github_token.id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "github_installation_id" => installation.id,
        "github_token_id" => github_token.id,
        "repositories" => { "acme/widgets" => "accessible" }
      )
    end
  end

  describe "POST /github_installations/:id/migrate" do
    it "routes to token migration handling" do
      installation = create(:github_installation, account: account)

      post migrate_project_github_installation_path(installation), params: { github_token_id: -1 }

      expect(response).to redirect_to(migrate_project_github_installation_path(installation))
    end
  end
end
