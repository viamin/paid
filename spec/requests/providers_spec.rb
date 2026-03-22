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
        expect(response.body).to include("Provider Priority")
        expect(response.body).to include("Primary Provider")
      end
    end
  end

  describe "PATCH /providers/settings" do
    before do
      sign_in user
      allow(ProviderSupport).to receive(:container_executable_provider_keys).and_return(%w[claude cursor aider])
    end

    it "updates provider priority settings from the providers page" do
      user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true)
      user.providers.create!(provider_key: "aider", enabled_for_agent_runs: false, enabled_for_fallback: true)

      patch settings_providers_path, params: {
        user_setting: {
          default_agent_provider: "cursor",
          fallback_enabled: true,
          fallback_providers: %w[claude aider].to_json
        }
      }

      expect(response).to redirect_to(providers_path)
      settings = user.reload.settings
      expect(settings.default_agent_provider).to eq("cursor")
      expect(settings.fallback_enabled).to be(true)
      expect(settings.fallback_providers).to eq(%w[claude aider])
    end
  end

  describe "POST /providers" do
    before { sign_in user }

    it "creates a container-executable provider with agent runs enabled" do
      allow(ProviderSupport).to receive(:container_executable_provider_key?).and_call_original
      allow(ProviderSupport).to receive(:container_executable_provider_key?).with("cursor").and_return(true)

      post providers_path, params: { provider: { provider_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true } }

      expect(response).to redirect_to(providers_path)
      expect(user.providers.find_by(provider_key: "cursor")).to be_present
    end

    it "handles an empty run-provider list during settings reconciliation" do
      allow(UserSetting).to receive(:enabled_agent_providers).with(user).and_return([], [ "claude" ])
      allow(ProviderSupport).to receive(:container_executable_provider_key?).and_return(true)

      post providers_path, params: { provider: { provider_key: "aider", enabled_for_agent_runs: true, enabled_for_fallback: true } }

      expect(response).to redirect_to(providers_path)
    end

    it "rejects unsupported providers" do
      post providers_path, params: { provider: { provider_key: "unknown_provider", enabled_for_agent_runs: true, enabled_for_fallback: true } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("is not currently available")
    end

    it "accepts non-executable providers without agent run or fallback flags" do
      post providers_path, params: { provider: { provider_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false } }

      expect(response).to redirect_to(providers_path)
      expect(user.providers.find_by(provider_key: "gemini")).to be_present
    end

    it "rejects non-executable providers when enabled_for_agent_runs is set" do
      post providers_path, params: { provider: { provider_key: "gemini", enabled_for_agent_runs: true, enabled_for_fallback: false } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("cannot be enabled")
    end

    it "accepts app provider aliases backed by agent harness providers" do
      post providers_path, params: { provider: { provider_key: "copilot", enabled_for_agent_runs: false, enabled_for_fallback: false } }

      expect(response).to redirect_to(providers_path)
      expect(user.providers.find_by(provider_key: "copilot")).to be_present
    end
  end

  describe "GET /providers/new" do
    before { sign_in user }

    it "does not offer provider keys already configured for the user" do
      user.providers.create!(provider_key: "cursor")

      get new_provider_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('value="cursor"')
    end
  end

  describe "PATCH /providers/:id" do
    before { sign_in user }

    it "updates provider flags" do
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

  describe "POST /providers/:id/test_agent" do
    context "when not authenticated" do
      it "redirects to sign in" do
        provider = create(:provider, user: user, provider_key: "cursor")

        post test_agent_provider_path(provider)

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns success when agent is healthy" do
        provider = user.providers.find_by!(provider_key: "claude")
        harness_response = AgentHarness::Response.new(
          output: "PING OK",
          exit_code: 0,
          duration: 1.0,
          provider: :claude
        )
        allow(AgentHarness).to receive(:send_message).and_return(harness_response)

        post test_agent_provider_path(provider), headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json["success"]).to be(true)
        expect(json["message"]).to eq("Agent is healthy")
      end

      it "returns error details when agent test fails" do
        provider = user.providers.find_by!(provider_key: "claude")
        allow(AgentHarness).to receive(:send_message)
          .and_raise(AgentHarness::AuthenticationError, "Invalid API key")

        post test_agent_provider_path(provider), headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json["success"]).to be(false)
        expect(json["error_type"]).to eq("authentication")
        expect(json["message"]).to eq("Invalid API key")
      end

      it "prevents testing another user's provider" do
        other_user = create(:user)
        other_provider = create(:provider, user: other_user, provider_key: "cursor")

        post test_agent_provider_path(other_provider), headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:not_found)
      end
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
