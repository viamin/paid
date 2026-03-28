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

      it "shows empty state when no addable providers remain" do
        allow(ProviderSupport).to receive(:addable_provider_keys).and_return([ "claude" ])

        get providers_path

        expect(response.body).to include("No More Providers Yet")
      end

      it "shows Add Provider link when addable providers are available" do
        allow(ProviderSupport).to receive(:addable_provider_keys).and_return(%w[claude cursor])

        get providers_path

        expect(response.body).to include("Add Provider")
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

    it "disables fallback for providers not in enabled_fallback_provider_keys" do
      user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true)
      user.providers.create!(provider_key: "aider", enabled_for_agent_runs: true, enabled_for_fallback: true)

      patch settings_providers_path, params: {
        user_setting: {
          default_agent_provider: "claude",
          fallback_enabled: true,
          fallback_providers: %w[cursor].to_json,
          enabled_fallback_provider_keys: %w[claude cursor].to_json
        }
      }

      expect(response).to redirect_to(providers_path)
      expect(user.providers.find_by(provider_key: "claude").enabled_for_fallback).to be(true)
      expect(user.providers.find_by(provider_key: "cursor").enabled_for_fallback).to be(true)
      expect(user.providers.find_by(provider_key: "aider").enabled_for_fallback).to be(false)
    end

    it "enables fallback for providers in enabled_fallback_provider_keys" do
      user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: false)

      patch settings_providers_path, params: {
        user_setting: {
          default_agent_provider: "claude",
          fallback_enabled: true,
          fallback_providers: %w[claude cursor].to_json,
          enabled_fallback_provider_keys: %w[claude cursor].to_json
        }
      }

      expect(response).to redirect_to(providers_path)
      expect(user.providers.find_by(provider_key: "cursor").enabled_for_fallback).to be(true)
    end

    it "preserves fallback flags when enabled_fallback_provider_keys is not sent" do
      user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: false)

      patch settings_providers_path, params: {
        user_setting: {
          default_agent_provider: "claude",
          fallback_enabled: true,
          fallback_providers: %w[claude].to_json
        }
      }

      expect(response).to redirect_to(providers_path)
      expect(user.providers.find_by(provider_key: "cursor").enabled_for_fallback).to be(false)
    end

    it "preserves fallback flags when enabled_fallback_provider_keys is malformed JSON" do
      user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true)

      patch settings_providers_path, params: {
        user_setting: {
          default_agent_provider: "claude",
          fallback_enabled: true,
          fallback_providers: %w[claude cursor].to_json,
          enabled_fallback_provider_keys: "not-valid-json{"
        }
      }

      expect(response).to redirect_to(providers_path)
      expect(user.providers.find_by(provider_key: "claude").enabled_for_fallback).to be(true)
      expect(user.providers.find_by(provider_key: "cursor").enabled_for_fallback).to be(true)
    end
  end

  describe "POST /providers" do
    before { sign_in user }

    it "creates a container-executable provider with agent runs enabled" do
      allow(ProviderSupport).to receive(:addable_provider_key?).and_call_original
      allow(ProviderSupport).to receive(:addable_provider_key?).with("cursor").and_return(true)

      post providers_path, params: { provider: { provider_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true } }

      expect(response).to redirect_to(providers_path)
      expect(user.providers.find_by(provider_key: "cursor")).to be_present
    end

    it "handles an empty run-provider list during settings reconciliation" do
      allow(UserSetting).to receive(:enabled_agent_providers).with(user).and_return([], [ "claude" ])
      allow(ProviderSupport).to receive(:addable_provider_key?).and_return(true)

      post providers_path, params: { provider: { provider_key: "aider", enabled_for_agent_runs: true, enabled_for_fallback: true } }

      expect(response).to redirect_to(providers_path)
    end

    it "rejects providers that are not supported" do
      post providers_path, params: { provider: { provider_key: "unknown_provider", enabled_for_agent_runs: true, enabled_for_fallback: true } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("is not supported")
    end

    it "rejects providers that are known to agent harness but not installed in paid-agent" do
      post providers_path, params: { provider: { provider_key: "aider", enabled_for_agent_runs: false, enabled_for_fallback: false } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("is not available in paid-agent yet")
    end

    it "handles duplicate provider gracefully" do
      allow(ProviderSupport).to receive(:addable_provider_key?).and_call_original
      allow(ProviderSupport).to receive(:addable_provider_key?).with("cursor").and_return(true)
      user.providers.create!(provider_key: "cursor")

      post providers_path, params: { provider: { provider_key: "cursor", auth_type: "subscription" } }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "preserves the submitted provider_key in options when re-rendering after duplicate subscription error" do
      allow(ProviderSupport).to receive(:addable_provider_key?).and_call_original
      allow(ProviderSupport).to receive(:addable_provider_key?).with("cursor").and_return(true)
      user.providers.create!(provider_key: "cursor")

      post providers_path, params: { provider: { provider_key: "cursor", auth_type: "subscription" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(assigns(:subscription_provider_options)).to include("cursor")
    end

    it "creates a gemini provider successfully" do
      post providers_path, params: { provider: { provider_key: "gemini", enabled_for_agent_runs: true, enabled_for_fallback: true } }

      expect(response).to redirect_to(providers_path)
      expect(user.providers.find_by(provider_key: "gemini")).to be_present
    end

    it "creates an opencode provider successfully" do
      post providers_path, params: { provider: { provider_key: "opencode", enabled_for_agent_runs: true, enabled_for_fallback: true } }

      expect(response).to redirect_to(providers_path)
      expect(user.providers.find_by(provider_key: "opencode")).to be_present
    end
  end

  describe "GET /providers/new" do
    before do
      sign_in user
      allow(ProviderSupport).to receive(:addable_provider_keys).and_return(%w[claude cursor])
    end

    it "does not offer provider keys already configured for the user" do
      user.providers.create!(provider_key: "cursor")

      get new_provider_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('value="cursor"')
    end

    it "shows an empty state when no additional paid-agent providers are installed" do
      allow(ProviderSupport).to receive(:addable_provider_keys).and_return([ "claude" ])

      get new_provider_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No additional providers are installed in paid-agent yet")
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

    it "rejects enabling agent runs on a provider that has become unsupported" do
      provider = user.providers.create!(provider_key: "cursor")

      allow(ProviderSupport).to receive(:supported_provider_key?).and_call_original
      allow(ProviderSupport).to receive(:supported_provider_key?).with("cursor").and_return(false)

      patch provider_path(provider), params: { provider: { enabled_for_agent_runs: true } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must be disabled for an unsupported provider")
    end

    it "rejects enabling fallback on a provider that has become unsupported" do
      provider = user.providers.create!(provider_key: "cursor")

      allow(ProviderSupport).to receive(:supported_provider_key?).and_call_original
      allow(ProviderSupport).to receive(:supported_provider_key?).with("cursor").and_return(false)

      patch provider_path(provider), params: { provider: { enabled_for_fallback: true } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must be disabled for an unsupported provider")
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
        result = instance_double(
          Providers::TestAgent::Result,
          success?: true,
          message: "Agent is healthy",
          error_type: nil
        )
        allow(Providers::TestAgent).to receive(:call).and_return(result)

        post test_agent_provider_path(provider), headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json["success"]).to be(true)
        expect(json["message"]).to eq("Agent is healthy")
      end

      it "returns error details when agent test fails" do
        provider = user.providers.find_by!(provider_key: "claude")
        result = instance_double(
          Providers::TestAgent::Result,
          success?: false,
          message: "Invalid API key",
          error_type: :authentication
        )
        allow(Providers::TestAgent).to receive(:call).and_return(result)

        post test_agent_provider_path(provider), headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json["success"]).to be(false)
        expect(json["error_type"]).to eq("authentication")
        expect(json["message"]).to eq("Invalid API key")
      end

      it "rate-limits repeated test requests for the same provider" do
        provider = user.providers.find_by!(provider_key: "claude")
        result = instance_double(
          Providers::TestAgent::Result,
          success?: true,
          message: "Agent is healthy",
          error_type: nil
        )
        allow(Providers::TestAgent).to receive(:call).and_return(result)

        # The test environment uses :null_store, so use a real store
        # to exercise the atomic rate-limit logic without mutating global state.
        store = ActiveSupport::Cache::MemoryStore.new
        allow(Rails).to receive(:cache).and_return(store)

        post test_agent_provider_path(provider), headers: { "Accept" => "application/json" }
        expect(response).to have_http_status(:ok)

        post test_agent_provider_path(provider), headers: { "Accept" => "application/json" }
        expect(response).to have_http_status(:too_many_requests)
        json = JSON.parse(response.body)
        expect(json["error_type"]).to eq("rate_limited")
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
