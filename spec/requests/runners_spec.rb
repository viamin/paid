# frozen_string_literal: true

require "rails_helper"
require "set"

RSpec.describe "Runners" do
  let(:user) { create(:user) }

  def kilocode_runner_params(api_key_id:, model:, preflight_timeout_seconds: nil)
    kilocode_config = {
      api_provider: "inception",
      model: model
    }
    kilocode_config[:preflight_timeout_seconds] = preflight_timeout_seconds if preflight_timeout_seconds

    {
      runner_key: "kilocode",
      auth_type: "api_key",
      provider_api_key_id: api_key_id,
      enabled_for_agent_runs: true,
      enabled_for_fallback: true,
      config: {
        kilocode: kilocode_config
      }
    }
  end

  describe "GET /runners" do
    context "when not authenticated" do
      it "redirects to sign in" do
        get runners_path

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      let(:opencode_api_key) { create(:provider_api_key, user: user, api_service_type: "openrouter") }

      before { sign_in user }

      it "renders index" do
        get runners_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Runners")
        expect(response.body).to include("Runner Priority")
        expect(response.body).to include("Automated Runner")
        expect(response.body).not_to include(">Primary Runner<")
        expect(response.body).to include("Per-Run-Type Defaults")
        expect(response.body).to include("PR Agent")
        expect(response.body).to include("Code Review Agent")
        expect(response.body).to include("fallback starts after it and wraps around")
        expect(response.body).to include("The active automated runner is excluded automatically for each run")
      end

      it "shows the chat eligibility column" do
        get runners_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Chat")
      end

      it "renders collapsed auth instructions for every supported runner" do
        get runners_path

        expect(response.body).to include("Runner Auth Setup")
        expect(response.body.scan(/<details[^>]*data-runner-instruction-key="/).size).to eq(Runner.supported_runner_keys.size)
        expect(response.body).not_to match(/<details[^>]*data-runner-instruction-key="[^"]+"[^>]*\sopen(?:\s|>)/)
        Runner.supported_runner_keys.each do |runner_key|
          expect(response.body).to include(%(data-runner-instruction-key="#{runner_key}"))
          expect(response.body).to include(Runner.display_name(runner_key))
        end
      end

      it "includes a KiloCode instructions block" do
        get runners_path

        expect(response.body).to include(%(data-runner-instruction-key="kilocode"))
        expect(response.body).to include(Runner.display_name("kilocode"))
        expect(response.body).to include("Set a KiloCode model ID on the runner record")
      end

      it "renders a generic checklist when runner-specific copy is missing" do
        allow(RunnerSupport).to receive(:supported_runner_keys).and_return(%w[claude mystery_provider])

        get runners_path

        expect(response.body).to include(%(data-runner-instruction-key="mystery_provider"))
        expect(response.body).to include("Runner-specific setup notes are not available yet")
        expect(response.body).to include("Generic Checklist")
      end

      it "shows empty state when no addable providers remain" do
        allow(RunnerSupport).to receive(:addable_runner_keys).and_return([ "claude" ])

        get runners_path

        expect(response.body).to include("No More Runners Yet")
      end

      it "shows Add Runner link when addable providers are available" do
        allow(RunnerSupport).to receive(:addable_runner_keys).and_return(%w[claude cursor])

        get runners_path

        expect(response.body).to include("Add Runner")
      end

      it "does not reuse canonical runner state for api-key entries" do
        runner = user.runners.create!(
          runner_key: "opencode",
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
        user.runner_states.create!(runner_name: runner.runner_key, circuit_opened_at: 1.minute.ago)

        get runners_path

        expect(response.body).to match(/Kimi K2\.5.*Available/m)
        expect(response.body).not_to match(/Kimi K2\.5.*Circuit Open/m)
      end

      it "prefers routed usage stats over runner-key aggregates for api-key entries" do
        runner = user.runners.create!(
          runner_key: "opencode",
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
        allow(Runners::UsageStats).to receive(:call).and_return(
          "opencode" => { runs_7d: 99, cost_cents_7d: 123_45, tokens_7d: 500_000, fallback_total: 0, fallback_rate: 0, fallback_switched: 0, rate_limit_events_7d: 0 },
          runner.routing_key => { runs_7d: 3, cost_cents_7d: 250, tokens_7d: 1_500, fallback_total: 0, fallback_rate: 0, fallback_switched: 0, rate_limit_events_7d: 0 }
        )

        get runners_path

        expect(response.body).to match(/Kimi K2\.5.*3 runs/m)
        expect(response.body).not_to match(/Kimi K2\.5.*99 runs/m)
      end

      it "renders multi-runner options only when more than one runner is enabled" do
        get runners_path
        expect(response.body).not_to include("Round Robin")
        expect(response.body).not_to include("Runner Weights")

        allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor])
        user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true)

        get runners_path
        expect(response.body).to include("Round Robin")
        expect(response.body).to include("Runner Weights")
      end

      it "still shows canonical runner state for subscription fallback entries" do
        cursor = user.runners.create!(
          runner_key: "cursor",
          auth_type: "subscription",
          enabled_for_agent_runs: true,
          enabled_for_fallback: true
        )
        user.runner_states.create!(
          runner_name: "cursor",
          circuit_state: "open",
          circuit_opened_at: 1.minute.ago
        )

        get runners_path

        expect(response.body).to match(/#{Regexp.escape(cursor.display_name)}.*Circuit open/m)
      end
    end
  end

  describe "PATCH /runners/settings" do
    before do
      sign_in user
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor aider])
    end

    it "updates runner priority settings from the providers page" do
      cursor = user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true)
      aider = user.runners.create!(runner_key: "aider", enabled_for_agent_runs: false, enabled_for_fallback: true)
      claude = user.runners.find_by!(runner_key: "claude")

      patch settings_runners_path, params: {
        user_setting: {
          default_agent_runner: "cursor",
          default_agent_runners_by_goal: { create_pr: "cursor", review: "claude" },
          fallback_enabled: true,
          fallback_runners: %w[claude aider].to_json
        }
      }

      expect(response).to redirect_to(runners_path)
      settings = user.reload.settings
      expect(settings.default_agent_runner).to eq(cursor.routing_key)
      expect(settings.default_agent_runners_by_goal).to eq("create_pr" => cursor.routing_key, "review" => claude.routing_key)
      expect(settings.fallback_enabled).to be(true)
      expect(settings.fallback_runners).to eq([ claude.routing_key, aider.routing_key ])
    end

    it "drops goal-specific defaults whose providers are no longer enabled during reconciliation" do
      cursor = user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true)
      user.settings.update!(
        default_agent_runner: "claude",
        default_agent_runners_by_goal: {
          "create_pr" => cursor.routing_key,
          "review" => user.runners.find_by!(runner_key: "claude").routing_key
        }
      )

      cursor.update!(enabled_for_agent_runs: false)

      patch settings_runners_path, params: {
        user_setting: {
          default_agent_runner: "claude",
          fallback_enabled: false,
          fallback_runners: [].to_json
        }
      }

      expect(response).to redirect_to(runners_path)
      expect(user.reload.settings.default_agent_runners_by_goal).to eq(
        "review" => user.runners.find_by!(runner_key: "claude").routing_key
      )
    end

    it "preserves saved goal defaults when submitted nested keys are all unpermitted" do
      claude = user.runners.find_by!(runner_key: "claude")
      user.settings.update!(
        default_agent_runner: claude.routing_key,
        default_agent_runners_by_goal: { "review" => claude.routing_key }
      )

      patch settings_runners_path, params: {
        user_setting: {
          default_agent_runner: "claude",
          default_agent_runners_by_goal: { ship_it: "claude" },
          fallback_enabled: false,
          fallback_runners: [].to_json
        }
      }

      expect(response).to redirect_to(runners_path)
      expect(user.reload.settings.default_agent_runners_by_goal).to eq(
        "review" => claude.routing_key
      )
    end

    it "disables fallback for providers not in enabled_fallback_runner_keys" do
      user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true)
      user.runners.create!(runner_key: "aider", enabled_for_agent_runs: true, enabled_for_fallback: true)

      patch settings_runners_path, params: {
        user_setting: {
          default_agent_runner: "claude",
          fallback_enabled: true,
          fallback_runners: %w[cursor].to_json,
          enabled_fallback_runner_keys: %w[claude cursor].to_json
        }
      }

      expect(response).to redirect_to(runners_path)
      expect(user.runners.find_by(runner_key: "claude").enabled_for_fallback).to be(true)
      expect(user.runners.find_by(runner_key: "cursor").enabled_for_fallback).to be(true)
      expect(user.runners.find_by(runner_key: "aider").enabled_for_fallback).to be(false)
    end

    it "enables fallback for providers in enabled_fallback_runner_keys" do
      user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: false)

      patch settings_runners_path, params: {
        user_setting: {
          default_agent_runner: "claude",
          fallback_enabled: true,
          fallback_runners: %w[claude cursor].to_json,
          enabled_fallback_runner_keys: %w[claude cursor].to_json
        }
      }

      expect(response).to redirect_to(runners_path)
      expect(user.runners.find_by(runner_key: "cursor").enabled_for_fallback).to be(true)
    end

    it "preserves fallback flags when enabled_fallback_runner_keys is not sent" do
      user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: false)

      patch settings_runners_path, params: {
        user_setting: {
          default_agent_runner: "claude",
          fallback_enabled: true,
          fallback_runners: %w[claude].to_json
        }
      }

      expect(response).to redirect_to(runners_path)
      expect(user.runners.find_by(runner_key: "cursor").enabled_for_fallback).to be(false)
    end

    it "preserves fallback flags when enabled_fallback_runner_keys is malformed JSON" do
      user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true)

      patch settings_runners_path, params: {
        user_setting: {
          default_agent_runner: "claude",
          fallback_enabled: true,
          fallback_runners: %w[claude cursor].to_json,
          enabled_fallback_runner_keys: "not-valid-json{"
        }
      }

      expect(response).to redirect_to(runners_path)
      expect(user.runners.find_by(runner_key: "claude").enabled_for_fallback).to be(true)
      expect(user.runners.find_by(runner_key: "cursor").enabled_for_fallback).to be(true)
    end

    it "persists runner_selection_mode and per-runner weights via combined runner_mode" do
      cursor = user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true)

      patch settings_runners_path, params: {
        user_setting: {
          runner_mode: "round_robin",
          runner_weights: { cursor.id.to_s => "5" },
          fallback_enabled: false,
          fallback_runners: [].to_json
        }
      }

      expect(response).to redirect_to(runners_path)
      expect(user.reload.settings.runner_selection_mode).to eq("round_robin")
      expect(cursor.reload.weight).to eq(5)
    end

    it "sets single mode and default_agent_runner from combined runner_mode" do
      cursor = user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true)

      patch settings_runners_path, params: {
        user_setting: {
          runner_mode: "single:#{cursor.routing_key}",
          fallback_enabled: false,
          fallback_runners: [].to_json
        }
      }

      expect(response).to redirect_to(runners_path)
      settings = user.reload.settings
      expect(settings.runner_selection_mode).to eq("single")
      expect(settings.default_agent_runner).to eq(cursor.routing_key)
    end

    it "rejects an invalid runner_selection_mode by ignoring the change" do
      user.settings.update!(runner_selection_mode: "single")

      patch settings_runners_path, params: {
        user_setting: {
          default_agent_runner: "claude",
          runner_selection_mode: "bogus",
          fallback_enabled: false,
          fallback_runners: [].to_json
        }
      }

      expect(response).to redirect_to(runners_path)
      expect(user.reload.settings.runner_selection_mode).to eq("single")
    end

    it "rejects non-positive weight values without persisting other changes" do
      cursor = user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true)
      cursor.update!(weight: 2)
      user.settings.update!(runner_selection_mode: "single")

      patch settings_runners_path, params: {
        user_setting: {
          runner_mode: "round_robin",
          runner_weights: { cursor.id.to_s => "0" },
          fallback_enabled: false,
          fallback_runners: [].to_json
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(cursor.reload.weight).to eq(2)
      expect(user.reload.settings.runner_selection_mode).to eq("single")
    end
  end

  describe "POST /runners" do
    before { sign_in user }

    it "creates a container-executable runner with agent runs enabled" do
      allow(RunnerSupport).to receive(:addable_runner_key?).and_call_original
      allow(RunnerSupport).to receive(:addable_runner_key?).with("cursor").and_return(true)

      post runners_path, params: { runner: { runner_key: "cursor", enabled_for_agent_runs: true, enabled_for_chat: false, enabled_for_fallback: true } }

      expect(response).to redirect_to(runners_path)
      expect(user.runners.find_by(runner_key: "cursor")).to have_attributes(enabled_for_chat: false)
    end

    it "handles an empty run-runner list during settings reconciliation" do
      allow(UserSetting).to receive(:enabled_agent_runners).with(user).and_return([], [ "claude" ])
      allow(RunnerSupport).to receive(:addable_runner_key?).and_return(true)

      post runners_path, params: { runner: { runner_key: "aider", enabled_for_agent_runs: true, enabled_for_fallback: true } }

      expect(response).to redirect_to(runners_path)
    end

    it "rejects providers that are not supported" do
      post runners_path, params: { runner: { runner_key: "unknown_provider", enabled_for_agent_runs: true, enabled_for_fallback: true } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("is not supported")
    end

    it "rejects providers that are known to agent harness but not installed in paid-agent" do
      # All current supported providers are container-executable, so stub the
      # set to simulate a runner whose CLI is not yet installed in the image.
      stub_const("RunnerSupport::CONTAINER_EXECUTABLE_RUNNER_KEYS", Set.new(%w[claude]))

      post runners_path, params: { runner: { runner_key: "codex", enabled_for_agent_runs: false, enabled_for_fallback: false } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("is not available in paid-agent yet")
    end

    it "handles duplicate runner gracefully" do
      allow(RunnerSupport).to receive(:addable_runner_key?).and_call_original
      allow(RunnerSupport).to receive(:addable_runner_key?).with("cursor").and_return(true)
      user.runners.create!(runner_key: "cursor")

      post runners_path, params: { runner: { runner_key: "cursor", auth_type: "subscription" } }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "preserves the submitted provider_key in options when re-rendering after duplicate subscription error" do
      allow(RunnerSupport).to receive(:addable_runner_key?).and_call_original
      allow(RunnerSupport).to receive(:addable_runner_key?).with("cursor").and_return(true)
      user.runners.create!(runner_key: "cursor")

      post runners_path, params: { runner: { runner_key: "cursor", auth_type: "subscription" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Cursor")
    end

    it "creates a gemini runner successfully" do
      post runners_path, params: { runner: { runner_key: "gemini", enabled_for_agent_runs: true, enabled_for_fallback: true } }

      expect(response).to redirect_to(runners_path)
      expect(user.runners.find_by(runner_key: "gemini")).to be_present
    end

    it "creates an opencode runner successfully" do
      post runners_path, params: { runner: { runner_key: "opencode", enabled_for_agent_runs: true, enabled_for_fallback: true } }

      expect(response).to redirect_to(runners_path)
      expect(user.runners.find_by(runner_key: "opencode")).to be_present
    end

    it "persists nested OpenCode config for API-key providers" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")

      post runners_path, params: {
        runner: {
          runner_key: "opencode",
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

      expect(response).to redirect_to(runners_path)
      runner = user.runners.find_by!(runner_key: "opencode", auth_type: "api_key")
      expect(runner.opencode_api_provider).to eq("openrouter")
      expect(runner.opencode_model_id).to eq("moonshotai/kimi-k2-0905")
    end

    it "creates an openrouter_free runner with default free tier mappings" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
      create(:llm_model, model_id: "free-low", provider: "deepseek", tier: "low", pricing_tier: "free", capability_score: 4.0)
      create(:llm_model, model_id: "free-mid", provider: "qwen", tier: "mid", pricing_tier: "free", capability_score: 6.0)
      create(:llm_model, model_id: "free-high", provider: "moonshot", tier: "high", pricing_tier: "free", capability_score: 8.0)

      post runners_path, params: {
        runner: {
          runner_key: "openrouter_free",
          auth_type: "api_key",
          provider_api_key_id: api_key.id,
          enabled_for_agent_runs: true,
          enabled_for_fallback: true
        }
      }

      expect(response).to redirect_to(runners_path)
      expect(user.runners.find_by!(runner_key: "openrouter_free", auth_type: "api_key").tier_model_ids).to eq(
        "low" => "free-low",
        "mid" => "free-mid",
        "high" => "free-high"
      )
    end

    it "rejects kilocode API-key providers without a model id" do
      api_key = create(:provider_api_key, user: user, api_service_type: "inception")

      post runners_path, params: {
        runner: kilocode_runner_params(api_key_id: api_key.id, model: "")
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must include a KiloCode model id")
    end

    it "persists nested KiloCode preflight timeout config for API-key runners" do
      api_key = create(:provider_api_key, user: user, api_service_type: "inception")

      post runners_path, params: {
        runner: kilocode_runner_params(
          api_key_id: api_key.id,
          model: "glm-5.1",
          preflight_timeout_seconds: "45"
        )
      }

      expect(response).to redirect_to(runners_path)
      runner = user.runners.find_by!(runner_key: "kilocode", auth_type: "api_key")
      expect(runner.kilocode_model_id).to eq("glm-5.1")
      expect(runner.kilocode_preflight_timeout_seconds).to eq(45)
    end

    it "rejects opencode API-key providers without a model id" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")

      post runners_path, params: {
        runner: {
          runner_key: "opencode",
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

    it "creates an aider runner successfully" do
      post runners_path, params: { runner: { runner_key: "aider", enabled_for_agent_runs: true, enabled_for_fallback: true } }

      expect(response).to redirect_to(runners_path)
      expect(user.runners.find_by(runner_key: "aider")).to be_present
    end
  end

  describe "GET /runners/new" do
    before do
      sign_in user
      allow(RunnerSupport).to receive(:addable_runner_keys).and_return(%w[claude cursor])
    end

    it "does not offer runner keys already configured for the user" do
      user.runners.create!(runner_key: "cursor")

      get new_runner_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('value="cursor"')
    end

    it "shows an empty state when no additional paid-agent providers are installed" do
      allow(RunnerSupport).to receive(:addable_runner_keys).and_return([ "claude" ])

      get new_runner_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No additional runners are installed in paid-agent yet")
    end

    it "offers aider in the API-key runner list when a compatible key exists" do
      create(:provider_api_key, user: user, api_service_type: "openrouter", name: "OpenRouter")
      allow(RunnerSupport).to receive(:addable_runner_keys).and_return(%w[claude aider])

      get new_runner_path(form_variant: "api_key")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('value="api_key"')
      expect(response.body).to include('id="runner_runner_key_api_key"')
      expect(response.body).to include('option value="aider"')
    end
  end

  describe "PATCH /runners/:id" do
    before { sign_in user }

    it "updates runner flags" do
      runner = user.runners.create!(runner_key: "cursor")

      patch runner_path(runner), params: { runner: { enabled_for_agent_runs: false, enabled_for_chat: false } }

      expect(response).to redirect_to(runners_path)
      expect(runner.reload.enabled_for_agent_runs).to be(false)
      expect(runner.reload.enabled_for_chat).to be(false)
    end

    it "persists the agent_co_author_trailer on update" do
      runner = user.runners.create!(runner_key: "cursor")
      trailer = "Co-Authored-By: Cursor <noreply@cursor.sh>"

      patch runner_path(runner), params: { runner: { agent_co_author_trailer: trailer } }

      expect(response).to redirect_to(runners_path)
      expect(runner.reload.agent_co_author_trailer).to eq(trailer)
    end

    it "persists tier_model_ids on update" do
      runner = user.runners.create!(runner_key: "cursor")
      create(:llm_model, model_id: "haiku-x", provider: "anthropic", tier: "low")
      create(:llm_model, model_id: "sonnet-x", provider: "anthropic", tier: "mid")
      create(:llm_model, model_id: "opus-x", provider: "anthropic", tier: "high")

      patch runner_path(runner), params: {
        runner: { tier_model_ids: { low: "haiku-x", mid: "sonnet-x", high: "opus-x" } }
      }

      expect(response).to redirect_to(runners_path)
      expect(runner.reload.tier_model_ids).to eq("low" => "haiku-x", "mid" => "sonnet-x", "high" => "opus-x")
    end

    it "persists complexity_thresholds on update" do
      runner = user.runners.create!(runner_key: "cursor")

      patch runner_path(runner), params: {
        runner: { complexity_thresholds: { low_max: "2", mid_max: "8" } }
      }

      expect(response).to redirect_to(runners_path)
      expect(runner.reload.complexity_thresholds).to eq("low_max" => 2, "mid_max" => 8)
    end

    it "rejects invalid complexity_thresholds" do
      runner = user.runners.create!(runner_key: "cursor")

      patch runner_path(runner), params: {
        runner: { complexity_thresholds: { low_max: "8", mid_max: "3" } }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("less than mid_max")
    end

    it "rejects enabling agent runs on a runner that has become unsupported" do
      runner = user.runners.create!(runner_key: "cursor")

      allow(RunnerSupport).to receive(:supported_runner_key?).and_call_original
      allow(RunnerSupport).to receive(:supported_runner_key?).with("cursor").and_return(false)

      patch runner_path(runner), params: { runner: { enabled_for_agent_runs: true } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must be disabled for an unsupported runner")
    end

    it "rejects enabling fallback on a runner that has become unsupported" do
      runner = user.runners.create!(runner_key: "cursor")

      allow(RunnerSupport).to receive(:supported_runner_key?).and_call_original
      allow(RunnerSupport).to receive(:supported_runner_key?).with("cursor").and_return(false)

      patch runner_path(runner), params: { runner: { enabled_for_fallback: true } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must be disabled for an unsupported runner")
    end

    it "rejects enabling chat on a runner that has become unsupported" do
      runner = user.runners.create!(runner_key: "cursor", enabled_for_chat: false)

      allow(RunnerSupport).to receive(:supported_runner_key?).and_call_original
      allow(RunnerSupport).to receive(:supported_runner_key?).with("cursor").and_return(false)

      patch runner_path(runner), params: { runner: { enabled_for_chat: true } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must be disabled for an unsupported runner")
    end

    it "does not allow changing provider_key after create" do
      runner = user.runners.find_by!(runner_key: "claude")
      user.runners.create!(runner_key: "cursor")

      patch runner_path(runner), params: { runner: { runner_key: "cursor" } }

      expect(response).to redirect_to(runners_path)
      expect(runner.reload.runner_key).to eq("claude")
    end

    it "preserves auth_type for the edit form without submitting it" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
      runner = user.runners.create!(
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
      )

      get edit_runner_path(runner)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-runner-form-auth-type-value="api_key"')
      expect(response.body).not_to include('name="runner[auth_type]"')
    end

    it "renders OpenCode config inputs disabled for non-OpenCode providers" do
      runner = user.runners.find_by!(runner_key: "claude")

      get edit_runner_path(runner)

      expect(response).to have_http_status(:ok)
      expect(response.body).to match(/name="runner\[config\]\[opencode\]\[api_provider\]".*disabled/m)
      expect(response.body).to match(/name="runner\[config\]\[opencode\]\[model\]".*disabled/m)
    end

    it "renders complexity_thresholds inputs with balanced bracket names so Rack parses them as a nested hash" do
      runner = user.runners.find_by!(runner_key: "claude")

      get edit_runner_path(runner)

      expect(response).to have_http_status(:ok)
      # Bracket balance is the load-bearing detail: name="runner[complexity_thresholds[low_max]]"
      # would parse as {"complexity_thresholds[low_max" => {"]" => ...}} and never reach the model.
      expect(response.body).to include('name="runner[complexity_thresholds][low_max]"')
      expect(response.body).to include('name="runner[complexity_thresholds][mid_max]"')
      expect(response.body).not_to include('name="runner[complexity_thresholds[low_max]]"')
      expect(response.body).not_to include('name="runner[complexity_thresholds[mid_max]]"')
    end

    it "renders remediation decision history on the edit page" do
      runner = user.runners.find_by!(runner_key: "claude")
      create(
        :remediation_decision,
        account: user.account,
        proposed_action: "disable_runner_fallback",
        action_target_type: "runner",
        action_target_id: runner.id.to_s,
        root_cause: "Fallback runner repeatedly failed"
      )

      get edit_runner_path(runner)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Decision History")
      expect(response.body).to include("Fallback runner repeatedly failed")
    end
  end

  describe "POST /runners/:id/test_agent" do
    context "when not authenticated" do
      it "redirects to sign in" do
        runner = create(:runner, user: user, runner_key: "cursor")

        post test_agent_runner_path(runner)

        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "returns success when agent is healthy" do
        runner = user.runners.find_by!(runner_key: "claude")
        result = instance_double(
          Runners::TestAgent::Result,
          success?: true,
          message: "Agent is healthy",
          error_type: nil
        )
        allow(Runners::TestAgent).to receive(:call).and_return(result)

        post test_agent_runner_path(runner), headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json["success"]).to be(true)
        expect(json["message"]).to eq("Agent is healthy")
      end

      it "returns error details when agent test fails" do
        runner = user.runners.find_by!(runner_key: "claude")
        result = instance_double(
          Runners::TestAgent::Result,
          success?: false,
          message: "Invalid API key",
          error_type: :authentication
        )
        allow(Runners::TestAgent).to receive(:call).and_return(result)

        post test_agent_runner_path(runner), headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json["success"]).to be(false)
        expect(json["error_type"]).to eq("authentication")
        expect(json["message"]).to eq("Invalid API key")
      end

      it "rate-limits repeated test requests for the same runner" do
        runner = user.runners.find_by!(runner_key: "claude")
        result = instance_double(
          Runners::TestAgent::Result,
          success?: true,
          message: "Agent is healthy",
          error_type: nil
        )
        allow(Runners::TestAgent).to receive(:call).and_return(result)

        # The test environment uses :null_store, so use a real store
        # to exercise the atomic rate-limit logic without mutating global state.
        store = ActiveSupport::Cache::MemoryStore.new
        allow(Rails).to receive(:cache).and_return(store)

        post test_agent_runner_path(runner), headers: { "Accept" => "application/json" }
        expect(response).to have_http_status(:ok)

        post test_agent_runner_path(runner), headers: { "Accept" => "application/json" }
        expect(response).to have_http_status(:too_many_requests)
        json = JSON.parse(response.body)
        expect(json["error_type"]).to eq("rate_limited")
      end

      it "prevents testing another user's runner" do
        other_user = create(:user)
        other_provider = create(:runner, user: other_user, runner_key: "cursor")

        post test_agent_runner_path(other_provider), headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "DELETE /runners/:id" do
    before { sign_in user }

    it "prevents deleting the last run-enabled runner" do
      runner = user.runners.find_by!(runner_key: "claude")

      delete runner_path(runner)

      expect(response).to redirect_to(runners_path)
      expect(flash[:alert]).to include("Cannot delete the last runner")
    end

    it "soft deletes providers instead of removing the row" do
      runner = create(:runner, user: user, runner_key: "cursor", name: "Cursor Stable")

      delete runner_path(runner)

      expect(response).to redirect_to(runners_path)
      expect(Runner.kept_only.find_by(id: runner.id)).to be_nil
      expect(Runner.with_discarded.find(runner.id)).to be_discarded
    end
  end
end
