# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Providers" do
  let(:user) { create(:user) }

  describe "GET /providers" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get providers_path

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders index" do
        get providers_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Providers")
      end
    end
  end

  describe "POST /providers" do
    before { sign_in user }

    it "creates a provider" do
      post providers_path, params: { provider: { provider_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true } }

      expect(response).to redirect_to(providers_path)
      expect(user.providers.find_by(provider_key: "cursor")).to be_present
    end

    it "handles an empty run-provider list during settings reconciliation" do
      allow(UserSetting).to receive(:enabled_agent_providers).with(user).and_return([], [ "claude" ])

      post providers_path, params: { provider: { provider_key: "aider", enabled_for_agent_runs: true, enabled_for_fallback: true } }

      expect(response).to redirect_to(providers_path)
    end
  end

  describe "GET /providers/new" do
    before { sign_in user }

    it "does not offer provider keys already configured for the user" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("CURSOR_ENABLED", "false").and_return("true")
      user.providers.create!(provider_key: "cursor")

      get new_provider_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('value="cursor"')
    end
  end

  describe "PATCH /providers/:id" do
    before { sign_in user }

    it "updates provider flags" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("CURSOR_ENABLED", "false").and_return("true")
      provider = user.providers.create!(provider_key: "cursor")

      patch provider_path(provider), params: { provider: { enabled_for_agent_runs: false } }

      expect(response).to redirect_to(providers_path)
      expect(provider.reload.enabled_for_agent_runs).to be(false)
    end

    it "does not allow changing provider_key after create" do
      provider = user.providers.find_by!(provider_key: "claude")
      user.providers.create!(provider_key: "cursor")

      patch provider_path(provider), params: { provider: { provider_key: "cursor" } }

      expect(response).to redirect_to(providers_path)
      expect(provider.reload.provider_key).to eq("claude")
    end
  end

  describe "DELETE /providers/:id" do
    before { sign_in user }

    it "prevents deleting the last run-enabled provider" do
      provider = user.providers.find_by!(provider_key: "claude")

      delete provider_path(provider)

      expect(response).to redirect_to(providers_path)
      expect(flash[:alert]).to include("Cannot delete the last provider")
    end
  end
end
