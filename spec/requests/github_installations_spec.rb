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

    it "refreshes stale repository caches for the visible repository count" do
      installation = create(
        :github_installation,
        account: account,
        accessible_repositories: [ repository_cache_entry(123, "acme/first-page") ],
        repositories_synced_at: nil
      )
      stub_installation_repository_sync(installation)

      get github_installation_path(installation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("acme/second-page")
      expect(installation.reload.accessible_repositories.size).to eq(2)
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

    it "refreshes stale installation repository caches before rendering options" do
      installation = create(
        :github_installation,
        account: account,
        accessible_repositories: [ repository_cache_entry(123, "acme/first-page") ],
        repositories_synced_at: nil
      )

      stub_installation_repository_sync(installation)

      get repositories_github_installation_path(installation)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.map { |repo| repo.fetch("full_name") }).to eq([
        "acme/first-page",
        "acme/second-page"
      ])
      expect(installation.reload.accessible_repositories.size).to eq(2)
      expect(installation.repositories_synced_at).to be_present
    end

    it "falls back to cached repositories when GitHub refresh fails" do
      installation = create(
        :github_installation,
        account: account,
        accessible_repositories: [ repository_cache_entry(123, "acme/cached") ],
        repositories_synced_at: nil
      )

      stub_failed_installation_repository_sync(installation)

      get repositories_github_installation_path(installation)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.map { |repo| repo.fetch("full_name") }).to eq([ "acme/cached" ])
      expect(installation.reload.repositories_synced_at).to be_nil
    end
  end

  def repository_cache_entry(id, full_name, default_branch: "main")
    { "id" => id, "full_name" => full_name, "default_branch" => default_branch }
  end

  def stub_installation_repository_sync(installation)
    allow(Github::AppRegistry).to receive(:configured?).and_return(true)
    allow(Github::InstallationRepositories).to receive(:fetch)
      .with(installation_id: installation.github_installation_id)
      .and_return([
        repository_cache_entry(123, "acme/first-page"),
        repository_cache_entry(456, "acme/second-page", default_branch: "trunk")
      ])
  end

  def stub_failed_installation_repository_sync(installation)
    allow(Github::AppRegistry).to receive(:configured?).and_return(true)
    allow(Github::InstallationRepositories).to receive(:fetch)
      .with(installation_id: installation.github_installation_id)
      .and_raise(Github::InstallationRepositories::Error, "timeout")
  end

  describe "GET /github_installations/:id/migrate" do
    it "routes to the migration form action" do
      installation = create(:github_installation, account: account)
      github_token = create(:github_token, account: account, created_by: user)
      create(:project, account: account, created_by: user, github_token: github_token)

      get migrate_project_github_installation_path(installation)

      expect(response).to have_http_status(:ok)
    end

    it "rejects account members without admin access" do
      member = create(:user, :member, account: account)
      installation = create(:github_installation, account: account)

      sign_out user
      sign_in member

      get migrate_project_github_installation_path(installation)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("You are not authorized to perform this action.")
    end

    it "redirects when the installation is not active" do
      installation = create(:github_installation, :revoked, account: account)

      get migrate_project_github_installation_path(installation)

      expect(response).to redirect_to(github_installation_path(installation))
      expect(flash[:alert]).to eq("GitHub App installation must be active")
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

    it "rejects inactive tokens" do
      installation = create(:github_installation, account: account)
      github_token = create(:github_token, account: account, created_by: user, revoked_at: Time.current)

      post check_access_github_installation_path(installation), params: { github_token_id: github_token.id }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("error" => "Active GitHub token not found")
    end
  end

  describe "POST /github_installations/:id/migrate" do
    it "routes to token migration handling" do
      installation = create(:github_installation, account: account)

      post migrate_project_github_installation_path(installation), params: { github_token_id: -1 }

      expect(response).to redirect_to(migrate_project_github_installation_path(installation))
    end

    it "includes per-project error details in the flash when migration fails" do
      installation = create(:github_installation, account: account)
      github_token = create(:github_token, account: account, created_by: user)
      project = create(:project, account: account, created_by: user, github_token: github_token, owner: "other-org", repo: "blocked")

      allow(Github::MigrationService).to receive(:migrate_from_token).and_return(
        Github::MigrationService::BulkResult.new(
          total: 1, successful: 0, failed: 1,
          results: [
            Github::MigrationService::Result.new(success: false, project: project, error: "Installation does not have access")
          ]
        )
      )

      post migrate_project_github_installation_path(installation), params: { github_token_id: github_token.id }

      expect(response).to redirect_to(migrate_project_github_installation_path(installation))
      expect(flash[:alert]).to include("other-org/blocked")
      expect(flash[:alert]).to include("Installation does not have access")
    end

    it "rejects inactive tokens" do
      installation = create(:github_installation, account: account)
      github_token = create(:github_token, account: account, created_by: user, revoked_at: Time.current)

      post migrate_project_github_installation_path(installation), params: { github_token_id: github_token.id }

      expect(response).to redirect_to(migrate_project_github_installation_path(installation))
      expect(flash[:alert]).to eq("Active GitHub token not found")
    end

    it "rejects account members without admin access" do
      member = create(:user, :member, account: account)
      installation = create(:github_installation, account: account)

      sign_out user
      sign_in member

      post migrate_project_github_installation_path(installation), params: { github_token_id: -1 }

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("You are not authorized to perform this action.")
    end
  end
end
