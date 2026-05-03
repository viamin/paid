# frozen_string_literal: true

require "rails_helper"

RSpec.describe "IntegrationCredentials" do
  let(:account) { create(:account) }
  let(:owner_user) { create(:user, account: account) }
  let(:admin_user) { create(:user, :admin, account: account) }
  let(:member_user) { create(:user, :member, account: account) }

  describe "GET /integration_credentials" do
    before { sign_in owner_user }

    it "filters credentials by category" do
      matching = create(:integration_credential, account: account, created_by: owner_user, service_key: "claude", category: "llm_provider", name: "Claude Token")
      create(:integration_credential, :gitlab, account: account, created_by: owner_user, name: "GitLab Token")

      get integration_credentials_path(category: "llm_provider")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(matching.name)
      expect(response.body).not_to include("GitLab Token")
    end

    context "when user is an admin" do
      before { sign_in admin_user }

      it "allows access" do
        get integration_credentials_path

        expect(response).to have_http_status(:ok)
      end
    end

    context "when user is a member" do
      before { sign_in member_user }

      it "denies access" do
        get integration_credentials_path

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "GET /integration_credentials/new" do
    before { sign_in owner_user }

    it "prefills service-specific forms from query params" do
      get new_integration_credential_path(service_key: "github_signing", category: "signing")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Add Credential")
      expect(response.body).to include("GitHub Signing")
    end

    context "when user is a member" do
      before { sign_in member_user }

      it "denies access" do
        get new_integration_credential_path

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "POST /integration_credentials" do
    before { sign_in owner_user }

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

      credential = IntegrationCredential.last
      expect(response).to redirect_to(integration_credential_path(credential, category: credential.category))
      expect(credential.service_key).to eq("gemini")
      expect(credential.created_by).to eq(owner_user)
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

    context "when user is a member" do
      before { sign_in member_user }

      it "denies access" do
        post integration_credentials_path, params: {
          integration_credential: {
            name: "Test",
            service_key: "gitlab",
            category: "repository",
            auth_kind: "api_key",
            secret: "secret-123"
          }
        }

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "GET /integration_credentials/:id" do
    before { sign_in owner_user }

    it "shows the credential details" do
      credential = create(:integration_credential, account: account, created_by: owner_user, name: "My Claude Key")

      get integration_credential_path(credential)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("My Claude Key")
    end

    it "does not show credentials from other accounts" do
      other_account = create(:account)
      other_credential = create(:integration_credential, account: other_account)

      get integration_credential_path(other_credential)

      expect(response).to have_http_status(:not_found)
    end

    context "when user is a member" do
      before { sign_in member_user }

      it "denies access" do
        credential = create(:integration_credential, account: account, created_by: owner_user, name: "My Key")

        get integration_credential_path(credential)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "DELETE /integration_credentials/:id" do
    context "when user has owner role" do
      before { sign_in owner_user }

      it "revokes the credential and redirects to index" do
        credential = create(:integration_credential, account: account, created_by: owner_user)

        delete integration_credential_path(credential)

        expect(credential.reload).to be_revoked
        expect(response).to redirect_to(integration_credentials_path(category: credential.category))
        follow_redirect!
        expect(response.body).to include("deactivated")
      end

      it "preserves return filter params when provided" do
        credential = create(:integration_credential, account: account, created_by: owner_user, service_key: "claude", category: "llm_provider")

        delete integration_credential_path(credential, category: "llm_provider", service_key: "claude")

        expect(response).to redirect_to(integration_credentials_path(category: "llm_provider", service_key: "claude"))
      end
    end

    context "when user has admin role" do
      before { sign_in admin_user }

      it "revokes the credential" do
        credential = create(:integration_credential, account: account, created_by: owner_user)

        delete integration_credential_path(credential)

        expect(credential.reload).to be_revoked
        expect(response).to redirect_to(integration_credentials_path(category: credential.category))
      end
    end

    context "when user is a member" do
      before { sign_in member_user }

      it "denies access" do
        credential = create(:integration_credential, account: account, created_by: owner_user)

        delete integration_credential_path(credential)

        expect(response).to have_http_status(:not_found)
      end
    end

    context "when credential belongs to another account" do
      before { sign_in owner_user }

      it "is not accessible" do
        other_account = create(:account)
        other_credential = create(:integration_credential, account: other_account)

        delete integration_credential_path(other_credential)

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
