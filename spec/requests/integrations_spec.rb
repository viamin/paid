# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Integrations" do
  let(:account) { create(:account) }
  let(:owner_user) { create(:user, :owner, account: account) }
  let(:admin_user) { create(:user, :admin, account: account) }
  let(:member_user) { create(:user, :member, account: account) }

  describe "GET /integrations" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get integrations_path

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when signed in as the account owner" do
      before { sign_in owner_user }

      it "renders the integrations page" do
        get integrations_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Integrations")
      end

      it "shows empty state when no integrations are configured" do
        get integrations_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("No integrations configured")
        expect(response.body).to include("Add Integration")
      end

      it "shows GitHub App installation guidance" do
        get integrations_path

        expect(response.body).to include("Install the <code>paid-agents</code> GitHub App")
        install_href = if Github::AppRegistry.configured?
          github_app_install_path
        else
          Github::AppRegistry.install_url
        end
        expect(response.body).to include(%(href="#{install_href}"))
        expect(response.body).to include("Repository")
        expect(response.body).to include("User Account")
        expect(response.body).to include("Organization")
        expect(response.body).to include("No active <code>paid-agents</code> installation has been detected")
      end

      it "shows GitHub App installation coverage when installations exist" do
        installation = create(:github_installation, account: account, accessible_repositories: [ { "id" => 123, "full_name" => "acme/widgets" } ])
        create(:project, :with_github_installation, account: account, created_by: owner_user, owner: "acme", repo: "widgets", github_id: 123, github_installation: installation)
        create(:project, account: account, created_by: owner_user, owner: "acme", repo: "pilot", github_id: 456, github_token: create(:github_token, account: account, created_by: owner_user))

        get integrations_path

        expect(response.body).to include("active <code>paid-agents</code> installation")
        expect(response.body).to include("Projects covered by an active installation")
        expect(response.body).to include("Projects already using GitHub App auth")
        expect(response.body).to include("View Installations")
      end

      it "shows installation coverage rows when active and revoked app connections both exist" do
        active_installation = create(:github_installation, account: account, accessible_repositories: [ { "id" => 123, "full_name" => "acme/widgets" } ])
        revoked_installation = create(:github_installation, account: account, accessible_repositories: [ { "id" => 456, "full_name" => "acme/retired" } ])

        create(:project, :with_github_installation, account: account, created_by: owner_user, owner: "acme", repo: "widgets", github_id: 123, github_installation: active_installation)
        create(:project, :with_github_installation, account: account, created_by: owner_user, owner: "acme", repo: "retired", github_id: 456, github_installation: revoked_installation)
        revoked_installation.update!(revoked_at: Time.current)

        get integrations_path

        expect(response.body).to include("Projects covered by an active installation")
        expect(response.body).to include("Projects already using GitHub App auth")
        expect(response.body).to include("active <code>paid-agents</code> installation")
      end

      it "shows configured integrations grouped by type" do
        github_token = create(:github_token, account: account)
        provider_key = create(:provider_api_key, user: owner_user)

        get integrations_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Repository Access")
        expect(response.body).to include(github_token.name)
        expect(response.body).to include("LLM Providers")
        expect(response.body).to include(provider_key.name)
        expect(response.body).not_to include("Issue Tracking")
      end
    end

    context "when signed in as an admin" do
      before { sign_in admin_user }

      it "shows integration credentials section for admin users" do
        create(:integration_credential, :gitlab, account: account, created_by: owner_user, name: "GitLab Prod")

        get integrations_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Integration Credentials")
        expect(response.body).to include("GitLab Prod")
      end

      it "excludes revoked and expired integration credentials" do
        create(:integration_credential, :gitlab, account: account, created_by: owner_user, name: "Active Cred")
        create(:integration_credential, :gitlab, :revoked, account: account, created_by: owner_user, name: "Revoked Cred")
        create(
          :integration_credential,
          :gitlab,
          account: account,
          created_by: owner_user,
          expires_at: 1.day.ago,
          name: "Expired Cred"
        )

        get integrations_path

        expect(response.body).to include("Active Cred")
        expect(response.body).not_to include("Revoked Cred")
        expect(response.body).not_to include("Expired Cred")
      end
    end

    context "when user is a member" do
      before { sign_in member_user }

      it "does not show integration credentials section" do
        create(:integration_credential, :gitlab, account: account, created_by: owner_user, name: "GitLab Prod")

        get integrations_path

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("Integration Credentials")
        expect(response.body).not_to include("GitLab Prod")
      end
    end
  end

  describe "GET /integrations/new" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get new_integration_path

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when signed in as the account owner" do
      before { sign_in owner_user }

      it "renders the type chooser page" do
        get new_integration_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Add Integration")
        expect(response.body).to include("Source code access token")
        expect(response.body).to include("Issue tracker API key")
        expect(response.body).to include("LLM provider API key")
      end
    end

    context "when signed in as an admin" do
      before { sign_in admin_user }

      it "shows integration credential option for admin users" do
        get new_integration_path

        expect(response.body).to include("Integration credential")
        expect(response.body).to include("GitLab, Bitbucket, Jira, Slack, Teams")
      end
    end

    context "when user is a member" do
      before { sign_in member_user }

      it "does not show integration credential option" do
        get new_integration_path

        expect(response.body).not_to include("Integration credential")
      end
    end
  end
end
