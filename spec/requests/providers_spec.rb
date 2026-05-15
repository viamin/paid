# frozen_string_literal: true

require "rails_helper"
require "set"

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
      let(:opencode_api_key) { create(:provider_api_key, user: user, api_service_type: "openrouter") }

      before { sign_in user }

      it "renders index" do
        get providers_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Providers")
        expect(response.body).to include("Provider Priority")
        expect(response.body).to include("Automated Provider")
        expect(response.body).not_to include(">Primary Provider<")
        expect(response.body).to include("Per-Run-Type Defaults")
        expect(response.body).to include("PR Agent")
        expect(response.body).to include("Code Review Agent")
        expect(response.body).to include("fallback starts after it and wraps around")
        expect(response.body).to include("The active automated provider is excluded automatically for each run")
      end

      it "renders collapsed auth instructions for every supported provider" do
        get providers_path

        expect(response.body).to include("Provider Auth Setup")
        expect(response.body.scan(/<details[^>]*data-provider-instruction-key="/).size).to eq(Provider.supported_provider_keys.size)
        expect(response.body).not_to match(/<details[^>]*data-provider-instruction-key="[^"]+"[^>]*\sopen(?:\s|>)/)
        Provider.supported_provider_keys.each do |provider_key|
          expect(response.body).to include(%(data-provider-instruction-key="#{provider_key}"))
          expect(response.body).to include(Provider.display_name(provider_key))
        end
      end

      it "includes a KiloCode instructions block" do
        get providers_path

        expect(response.body).to include(%(data-provider-instruction-key="kilocode"))
        expect(response.body).to include(Provider.display_name("kilocode"))
        expect(response.body).to include("Set a KiloCode model ID on the provider record")
      end

      it "renders a generic checklist when provider-specific copy is missing" do
        allow(ProviderSupport).to receive(:supported_provider_keys).and_return(%w[claude mystery_provider])

        get providers_path

        expect(response.body).to include(%(data-provider-instruction-key="mystery_provider"))
        expect(response.body).to include("Provider-specific setup notes are not available yet")
        expect(response.body).to include("Generic Checklist")
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

      it "does not reuse canonical provider state for api-key entries" do
        provider = user.providers.create!(
          provider_key: "opencode",
          auth_type: "api_key",
          provider_api_key: opencode_api_key,
          name: "Kimi K2.5",
          enabled_for_agent_runs: true,
          config: {
            "opencode" => {
              "api_provider" => "openrouter",
              "model" => "moonshotai/kimi-k2-0905"
            }
          }
        )
        user.provider_states.create!(provider_name: provider.provider_key, circuit_opened_at: 1.minute.ago)

        get providers_path

        expect(response.body).to match(/Kimi K2\.5.*Available/m)
        expect(response.body).not_to match(/Kimi K2\.5.*Circuit Open/m)
      end

      it "prefers routed usage stats over provider-key aggregates for api-key entries" do
        provider = user.providers.create!(
          provider_key: "opencode",
          auth_type: "api_key",
          provider_api_key: opencode_api_key,
          name: "Kimi K2.5",
          enabled_for_agent_runs: true,
          config: {
            "opencode" => {
              "api_provider" => "openrouter",
              "model" => "moonshotai/kimi-k2-0905"
            }
          }
        )
        allow(Providers::UsageStats).to receive(:call).and_return(
          "opencode" => { runs_7d: 99, cost_cents_7d: 123_45, tokens_7d: 500_000, fallback_total: 0, fallback_rate: 0, fallback_switched: 0, rate_limit_events_7d: 0 },
          provider.routing_key => { runs_7d: 3, cost_cents_7d: 250, tokens_7d: 1_500, fallback_total: 0, fallback_rate: 0, fallback_switched: 0, rate_limit_events_7d: 0 }
        )

        get providers_path

        expect(response.body).to match(/Kimi K2\.5.*3 runs/m)
        expect(response.body).not_to match(/Kimi K2\.5.*99 runs/m)
      end

      it "renders multi-provider options only when more than one provider is enabled" do
        get providers_path
        expect(response.body).not_to include("Round Robin")
        expect(response.body).not_to include("Provider Weights")

        allow(ProviderSupport).to receive(:container_executable_provider_keys).and_return(%w[claude cursor])
        user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: true)

        get providers_path
        expect(response.body).to include("Round Robin")
        expect(response.body).to include("Provider Weights")
      end

      it "still shows canonical provider state for subscription fallback entries" do
        cursor = user.providers.create!(
          provider_key: "cursor",
          auth_type: "subscription",
          enabled_for_agent_runs: true,
          enabled_for_fallback: true
        )
        user.provider_states.create!(
          provider_name: "cursor",
          circuit_state: "open",
          circuit_opened_at: 1.minute.ago
        )

        get providers_path

        expect(response.body).to match(/#{Regexp.escape(cursor.display_name)}.*Circuit open/m)
      end
    end
  end

  describe "PATCH /providers/settings" do
    before do
      sign_in user
      allow(ProviderSupport).to receive(:container_executable_provider_keys).and_return(%w[claude cursor aider])
    end

    it "updates provider priority settings from the providers page" do
      cursor = user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true)
      aider = user.providers.create!(provider_key: "aider", enabled_for_agent_runs: false, enabled_for_fallback: true)
      claude = user.providers.find_by!(provider_key: "claude")

      patch settings_providers_path, params: {
        user_setting: {
          default_agent_provider: "cursor",
          default_agent_providers_by_goal: { create_pr: "cursor", review: "claude" },
          fallback_enabled: true,
          fallback_providers: %w[claude aider].to_json
        }
      }

      expect(response).to redirect_to(providers_path)
      settings = user.reload.settings
      expect(settings.default_agent_provider).to eq(cursor.routing_key)
      expect(settings.default_agent_providers_by_goal).to eq("create_pr" => cursor.routing_key, "review" => claude.routing_key)
      expect(settings.fallback_enabled).to be(true)
      expect(settings.fallback_providers).to eq([ claude.routing_key, aider.routing_key ])
    end

    it "drops goal-specific defaults whose providers are no longer enabled during reconciliation" do
      cursor = user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true)
      user.settings.update!(
        default_agent_provider: "claude",
        default_agent_providers_by_goal: {
          "create_pr" => cursor.routing_key,
          "review" => user.providers.find_by!(provider_key: "claude").routing_key
        }
      )

      cursor.update!(enabled_for_agent_runs: false)

      patch settings_providers_path, params: {
        user_setting: {
          default_agent_provider: "claude",
          fallback_enabled: false,
          fallback_providers: [].to_json
        }
      }

      expect(response).to redirect_to(providers_path)
      expect(user.reload.settings.default_agent_providers_by_goal).to eq(
        "review" => user.providers.find_by!(provider_key: "claude").routing_key
      )
    end

    it "preserves saved goal defaults when submitted nested keys are all unpermitted" do
      claude = user.providers.find_by!(provider_key: "claude")
      user.settings.update!(
        default_agent_provider: claude.routing_key,
        default_agent_providers_by_goal: { "review" => claude.routing_key }
      )

      patch settings_providers_path, params: {
        user_setting: {
          default_agent_provider: "claude",
          default_agent_providers_by_goal: { ship_it: "claude" },
          fallback_enabled: false,
          fallback_providers: [].to_json
        }
      }

      expect(response).to redirect_to(providers_path)
      expect(user.reload.settings.default_agent_providers_by_goal).to eq(
        "review" => claude.routing_key
      )
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

    it "persists provider_selection_mode and per-provider weights via combined provider_mode" do
      cursor = user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: true)

      patch settings_providers_path, params: {
        user_setting: {
          provider_mode: "round_robin",
          provider_weights: { cursor.id.to_s => "5" },
          fallback_enabled: false,
          fallback_providers: [].to_json
        }
      }

      expect(response).to redirect_to(providers_path)
      expect(user.reload.settings.provider_selection_mode).to eq("round_robin")
      expect(cursor.reload.weight).to eq(5)
    end

    it "sets single mode and default_agent_provider from combined provider_mode" do
      cursor = user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: true)

      patch settings_providers_path, params: {
        user_setting: {
          provider_mode: "single:#{cursor.routing_key}",
          fallback_enabled: false,
          fallback_providers: [].to_json
        }
      }

      expect(response).to redirect_to(providers_path)
      settings = user.reload.settings
      expect(settings.provider_selection_mode).to eq("single")
      expect(settings.default_agent_provider).to eq(cursor.routing_key)
    end

    it "rejects an invalid provider_selection_mode by ignoring the change" do
      user.settings.update!(provider_selection_mode: "single")

      patch settings_providers_path, params: {
        user_setting: {
          default_agent_provider: "claude",
          provider_selection_mode: "bogus",
          fallback_enabled: false,
          fallback_providers: [].to_json
        }
      }

      expect(response).to redirect_to(providers_path)
      expect(user.reload.settings.provider_selection_mode).to eq("single")
    end

    it "rejects non-positive weight values without persisting other changes" do
      cursor = user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: true)
      cursor.update!(weight: 2)
      user.settings.update!(provider_selection_mode: "single")

      patch settings_providers_path, params: {
        user_setting: {
          provider_mode: "round_robin",
          provider_weights: { cursor.id.to_s => "0" },
          fallback_enabled: false,
          fallback_providers: [].to_json
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(cursor.reload.weight).to eq(2)
      expect(user.reload.settings.provider_selection_mode).to eq("single")
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
      # All current supported providers are container-executable, so stub the
      # set to simulate a provider whose CLI is not yet installed in the image.
      stub_const("ProviderSupport::CONTAINER_EXECUTABLE_PROVIDER_KEYS", Set.new(%w[claude]))

      post providers_path, params: { provider: { provider_key: "codex", enabled_for_agent_runs: false, enabled_for_fallback: false } }

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
      expect(response.body).to include("Cursor")
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

    it "persists nested OpenCode config for API-key providers" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")

      post providers_path, params: {
        provider: {
          provider_key: "opencode",
          auth_type: "api_key",
          provider_api_key_id: api_key.id,
          enabled_for_agent_runs: true,
          enabled_for_fallback: true,
          config: {
            opencode: {
              api_provider: "openrouter",
              model: "moonshotai/kimi-k2-0905"
            }
          }
        }
      }

      expect(response).to redirect_to(providers_path)
      provider = user.providers.find_by!(provider_key: "opencode", auth_type: "api_key")
      expect(provider.opencode_api_provider).to eq("openrouter")
      expect(provider.opencode_model_id).to eq("moonshotai/kimi-k2-0905")
    end

    it "rejects kilocode API-key providers without a model id" do
      api_key = create(:provider_api_key, user: user, api_service_type: "inception")

      post providers_path, params: {
        provider: {
          provider_key: "kilocode",
          auth_type: "api_key",
          provider_api_key_id: api_key.id,
          enabled_for_agent_runs: true,
          enabled_for_fallback: true,
          config: {
            kilocode: {
              api_provider: "inception",
              model: ""
            }
          }
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must include a KiloCode model id")
    end

    it "rejects opencode API-key providers without a model id" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")

      post providers_path, params: {
        provider: {
          provider_key: "opencode",
          auth_type: "api_key",
          provider_api_key_id: api_key.id,
          enabled_for_agent_runs: true,
          enabled_for_fallback: true,
          config: {
            opencode: {
              api_provider: "openrouter",
              model: ""
            }
          }
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must include an OpenCode model id")
    end

    it "creates an aider provider successfully" do
      post providers_path, params: { provider: { provider_key: "aider", enabled_for_agent_runs: true, enabled_for_fallback: true } }

      expect(response).to redirect_to(providers_path)
      expect(user.providers.find_by(provider_key: "aider")).to be_present
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

    it "persists the agent_co_author_trailer on update" do
      provider = user.providers.create!(provider_key: "cursor")
      trailer = "Co-Authored-By: Cursor <noreply@cursor.sh>"

      patch provider_path(provider), params: { provider: { agent_co_author_trailer: trailer } }

      expect(response).to redirect_to(providers_path)
      expect(provider.reload.agent_co_author_trailer).to eq(trailer)
    end

    it "persists tier_model_ids on update" do
      provider = user.providers.create!(provider_key: "cursor")
      create(:llm_model, model_id: "haiku-x", provider: "anthropic", tier: "low")
      create(:llm_model, model_id: "sonnet-x", provider: "anthropic", tier: "mid")
      create(:llm_model, model_id: "opus-x", provider: "anthropic", tier: "high")

      patch provider_path(provider), params: {
        provider: { tier_model_ids: { low: "haiku-x", mid: "sonnet-x", high: "opus-x" } }
      }

      expect(response).to redirect_to(providers_path)
      expect(provider.reload.tier_model_ids).to eq("low" => "haiku-x", "mid" => "sonnet-x", "high" => "opus-x")
    end

    it "persists complexity_thresholds on update" do
      provider = user.providers.create!(provider_key: "cursor")

      patch provider_path(provider), params: {
        provider: { complexity_thresholds: { low_max: "2", mid_max: "8" } }
      }

      expect(response).to redirect_to(providers_path)
      expect(provider.reload.complexity_thresholds).to eq("low_max" => 2, "mid_max" => 8)
    end

    it "rejects invalid complexity_thresholds" do
      provider = user.providers.create!(provider_key: "cursor")

      patch provider_path(provider), params: {
        provider: { complexity_thresholds: { low_max: "8", mid_max: "3" } }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("less than mid_max")
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

    it "preserves auth_type for the edit form without submitting it" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
      provider = user.providers.create!(
        provider_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
      )

      get edit_provider_path(provider)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-provider-form-auth-type-value="api_key"')
      expect(response.body).not_to include('name="provider[auth_type]"')
    end

    it "renders OpenCode config inputs disabled for non-OpenCode providers" do
      provider = user.providers.find_by!(provider_key: "claude")

      get edit_provider_path(provider)

      expect(response).to have_http_status(:ok)
      expect(response.body).to match(/name="provider\[config\]\[opencode\]\[api_provider\]".*disabled/m)
      expect(response.body).to match(/name="provider\[config\]\[opencode\]\[model\]".*disabled/m)
    end

    it "renders complexity_thresholds inputs with balanced bracket names so Rack parses them as a nested hash" do
      provider = user.providers.find_by!(provider_key: "claude")

      get edit_provider_path(provider)

      expect(response).to have_http_status(:ok)
      # Bracket balance is the load-bearing detail: name="provider[complexity_thresholds[low_max]]"
      # would parse as {"complexity_thresholds[low_max" => {"]" => ...}} and never reach the model.
      expect(response.body).to include('name="provider[complexity_thresholds][low_max]"')
      expect(response.body).to include('name="provider[complexity_thresholds][mid_max]"')
      expect(response.body).not_to include('name="provider[complexity_thresholds[low_max]]"')
      expect(response.body).not_to include('name="provider[complexity_thresholds[mid_max]]"')
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

    it "soft deletes providers instead of removing the row" do
      provider = create(:provider, user: user, provider_key: "cursor", name: "Cursor Stable")

      delete provider_path(provider)

      expect(response).to redirect_to(providers_path)
      expect(Provider.kept_only.find_by(id: provider.id)).to be_nil
      expect(Provider.with_discarded.find(provider.id)).to be_discarded
    end
  end
end
