# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Integrations" do
  let(:user) { create(:user) }

  describe "GET /integrations" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get integrations_path

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the integrations page" do
        get integrations_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Integrations")
      end

      it "shows empty state when no integrations are configured" do
        get integrations_path

        expect(response.body).to include("No integrations configured")
        expect(response.body).to include("Add Integration")
      end

      it "shows configured integrations grouped by type" do
        create(:github_token, account: user.account)
        create(:provider_api_key, user: user)

        get integrations_path

        expect(response.body).to include("Repository Access")
        expect(response.body).to include("LLM Providers")
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

    context "when authenticated" do
      before { sign_in user }

      it "renders the type chooser page" do
        get new_integration_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Add Integration")
        expect(response.body).to include("Source code access token")
        expect(response.body).to include("Issue tracker API key")
        expect(response.body).to include("LLM provider API key")
      end
    end
  end
end
