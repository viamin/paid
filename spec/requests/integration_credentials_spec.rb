# frozen_string_literal: true

require "rails_helper"

RSpec.describe "IntegrationCredentials" do
  let(:user) { create(:user) }

  describe "GET /integration_credentials" do
    before { sign_in user }

    it "filters credentials by category" do
      matching = create(:integration_credential, account: user.account, created_by: user, service_key: "claude", category: "llm_provider", name: "Claude Token")
      create(:integration_credential, :gitlab, account: user.account, created_by: user, name: "GitLab Token")

      get integration_credentials_path(category: "llm_provider")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(matching.name)
      expect(response.body).not_to include("GitLab Token")
    end
  end

  describe "GET /integration_credentials/new" do
    before { sign_in user }

    it "prefills service-specific forms from query params" do
      get new_integration_credential_path(service_key: "github_signing", category: "signing")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Add Credential")
      expect(response.body).to include("GitHub Signing")
    end
  end

  describe "POST /integration_credentials" do
    before { sign_in user }

    it "creates provider credentials" do
      post integration_credentials_path, params: {
        integration_credential: {
          name: "Gemini OAuth",
          service_key: "gemini",
          category: "llm_provider",
          auth_kind: "oauth_token",
          secret: "oauth-123"
        }
      }

      expect(response).to redirect_to(integration_credential_path(IntegrationCredential.last))
      expect(IntegrationCredential.last.service_key).to eq("gemini")
      expect(IntegrationCredential.last.created_by).to eq(user)
    end

    it "rejects invalid signing auth types" do
      post integration_credentials_path, params: {
        integration_credential: {
          name: "Bad Signing Credential",
          service_key: "github_signing",
          category: "signing",
          auth_kind: "oauth_token",
          secret: "oauth-123"
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("is not supported for GitHub Signing")
    end
  end

  describe "GET /integration_credentials/:id" do
    before { sign_in user }

    it "shows the credential details" do
      credential = create(:integration_credential, account: user.account, created_by: user, name: "My Claude Key")

      get integration_credential_path(credential)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("My Claude Key")
    end

    it "does not show credentials from other accounts" do
      other_account = create(:account)
      other_credential = create(:integration_credential, account: other_account)

      expect {
        get integration_credential_path(other_credential)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "DELETE /integration_credentials/:id" do
    context "when user has owner role" do
      before { sign_in user }

      it "revokes the credential and redirects to index" do
        credential = create(:integration_credential, account: user.account, created_by: user)

        delete integration_credential_path(credential)

        expect(credential.reload).to be_revoked
        expect(response).to redirect_to(integration_credentials_path(category: credential.category, service_key: credential.service_key))
        follow_redirect!
        expect(response.body).to include("deactivated")
      end

      it "preserves return filter params when provided" do
        credential = create(:integration_credential, account: user.account, created_by: user, service_key: "claude", category: "llm_provider")

        delete integration_credential_path(credential, category: "llm_provider")

        expect(response).to redirect_to(integration_credentials_path(category: "llm_provider", service_key: "claude"))
      end
    end

    context "when user does not have owner role" do
      let(:non_owner) { create(:user, account: user.account) }

      before { sign_in non_owner }

      it "denies access" do
        credential = create(:integration_credential, account: user.account, created_by: user)

        delete integration_credential_path(credential)

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end

    context "when credential belongs to another account" do
      before { sign_in user }

      it "is not accessible" do
        other_account = create(:account)
        other_credential = create(:integration_credential, account: other_account)

        expect {
          delete integration_credential_path(other_credential)
        }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
