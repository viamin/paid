# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Integrations" do
  let(:account) { create(:account) }
  let(:owner_user) { create(:user, account: account) }
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

      it "shows revoked and expired integration credentials with status" do
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

        expect(response.body).to include("Revoked Cred")
        expect(response.body).to include("Expired Cred")
        expect(response.body).to include("Revoked")
        expect(response.body).to include("Expired")
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
        expect(response.body).to include("GitLab, Jira, Azure DevOps")
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
