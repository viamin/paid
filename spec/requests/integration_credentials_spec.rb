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
end
