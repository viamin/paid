# frozen_string_literal: true

require "rails_helper"
require "set"

RSpec.describe "Runners" do
  let(:user) { create(:user) }

  def runners_index_document
    Nokogiri::HTML(response.body)
  end

  def runners_table_headers
    runners_index_document.css("table thead th").map { |header| header.text.strip }.reject(&:empty?)
  end

  def runner_table_row_for(name)
    runners_index_document.css("table tbody tr").find do |row|
      row.at_css("td")&.text&.include?(name)
    end
  end

  def checkbox_in(row, label)
    row.at_css(%(input[type="checkbox"][aria-label="#{label}"]))
  end

  def expect_disabled_checkbox(row:, label:, checked:, title:)
    checkbox = checkbox_in(row, label)

    expect(checkbox).to be_present
    expect(checkbox["disabled"]).to eq("disabled")
    expect(checkbox["checked"]).to eq("checked") if checked
    expect(checkbox["checked"]).to be_nil unless checked
    expect(checkbox["title"]).to eq(title)
  end

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

  def direct_outbound_runner_params(runner_key:, api_key_id:, model:)
    {
      runner_key: runner_key,
      auth_type: "api_key",
      provider_api_key_id: api_key_id,
      enabled_for_agent_runs: true,
      enabled_for_fallback: true,
      config: {
        runner_key => {
          model: model
        }
      }
    }
  end

  def free_policy_runner_params(api_key_id:, api_provider: "openrouter", enabled: false)
    {
      runner_key: "opencode",
      auth_type: "api_key",
      provider_api_key_id: api_key_id,
      enabled_for_agent_runs: enabled,
      enabled_for_chat: enabled,
      enabled_for_fallback: enabled,
      config: {
        opencode: {
          api_provider: api_provider,
          model_policy: "free"
        }
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
      let(:rate_limit_fallback_runner) do
        user.runners.create!(
          runner_key: "codex",
          auth_type: "api_key",
          provider_api_key: create(:provider_api_key, user: user, api_service_type: "openai"),
          enabled_for_agent_runs: true,
          enabled_for_chat: false,
          enabled_for_fallback: true,
          fallback_role: "rate_limit_fallback"
        )
      end

      before do
        sign_in user
        # Runner.direct_outbound_config_models_must_exist_in_catalog rejects direct-outbound
        # API-key runners whose model id is not present in the LlmModel catalog, so seed the
        # model ids used by direct user.runners.create! / post-runners-path calls in this spec.
        KnownDirectOutboundModels.seed_model(model_id: "moonshotai/kimi-k2-0905", provider: "openrouter")
        KnownDirectOutboundModels.seed_model(model_id: "glm-5.1", provider: "inception")
      end

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

      # @spec RUNNERS-INDEX-001
      it "renders Status immediately after Runner in the index table" do
        get runners_path

        expect(runners_table_headers).to include("Runner", "Status", "Auth")
        expect(runners_table_headers.index("Status")).to eq(runners_table_headers.index("Runner") + 1)
        expect(runners_table_headers.index("Status")).to be < runners_table_headers.index("Auth")
      end

      # @spec RUNNERS-INDEX-002
      it "renders Agent Runs and Chat as disabled checkboxes with matching state" do
        rate_limit_fallback_runner
        get runners_path

        row = runner_table_row_for(rate_limit_fallback_runner.display_name)

        expect(row).to be_present
        expect_disabled_checkbox(row: row, label: "Agent Runs", checked: true, title: "Enabled")
        expect_disabled_checkbox(row: row, label: "Chat", checked: false, title: "Disabled")
      end

      # @spec RUNNERS-INDEX-002
      # @spec RUNNERS-INDEX-003
      it "renders Fallback as a disabled checkbox with the rate-limit-only tooltip" do
        rate_limit_fallback_runner
        get runners_path

        row = runner_table_row_for(rate_limit_fallback_runner.display_name)

        expect(row).to be_present
        expect_disabled_checkbox(row: row, label: "Fallback", checked: true, title: "Enabled (rate-limit only)")
      end

      it "shows the free models badge and section for an openrouter_free runner" do
        free_model = create(:llm_model, model_id: "high-free", provider: "openrouter", tier: "high", pricing_tier: "free")
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
        user.runners.create!(
          runner_key: "openrouter_free",
          auth_type: "api_key",
          provider_api_key: api_key,
          tier_model_ids: LlmModel::TIERS.index_with { free_model.model_id }
        )

        get runners_path

        expect(response.body).to include("Open Catalog")
        expect(response.body.scan("Free Models").size).to be >= 2
      end

      # @spec RUNNERS-INDEX-005
      it "does not render the removed runner auth setup section" do
        get runners_path

        expect(response.body).not_to include("Runner Auth Setup")
        expect(response.body).not_to include("data-runner-auth-instructions")
      end

      # @spec RUNNERS-INDEX-008
      context "with provider run outcomes" do
        let(:project) { create(:project, account: user.account) }

        before do
          create(:agent_run, :completed, project: project, agent_type: "claude_code")
          create(:agent_run, :failed, project: project, agent_type: "claude_code")
        end

        %w[7d 30d cumulative].each do |range|
          it "renders the provider outcomes chart via the CSP-safe chartkick controller for #{range}" do
            get runners_path(outcome_time_range: range)

            doc = Nokogiri::HTML(response.body)
            chart = doc.at_css("div#provider-outcomes-chart-0[data-controller~='chartkick']")

            expect(chart).to be_present
            expect(chart["data-chartkick-type-value"]).to eq("ColumnChart")
            expect(chart["data-chartkick-options-value"]).to include("\"stacked\":true")
            expect(chart["data-chartkick-data-value"]).to be_present
            expect(chart.text).to include("Loading...")
            expect(response.body).not_to include("Chartkick.ColumnChart(")
          end
        end
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

      # @spec RUNNERS-INDEX-009
      it "renders the Test All header control wired to the row test controllers" do
        get runners_path

        doc = runners_index_document
        test_all_button = doc.at_css('[data-test-all-target="button"]')
        runner_row = doc.at_css('tr[data-controller="test-agent"][data-test-all-target="runner"]')
        row_button = runner_row&.at_css('[data-test-agent-target="button"]')

        expect(doc.at_css('[data-controller="test-all"]')).to be_present
        expect(test_all_button).to be_present
        expect(test_all_button.text.strip).to eq("Test All")
        expect(test_all_button["data-action"]).to eq("test-all#testAll")
        expect(runner_row).to be_present
        expect(row_button).to be_present
        expect(row_button.text.strip).to eq("Test Runner")
        expect(response.body).not_to include("Test Agent")
      end

      # @spec RUNNERS-INDEX-009
      it "omits the Test All header control when no configured runners are present" do
        Runner.where(user: user).delete_all

        get runners_path

        expect(runners_index_document.at_css('[data-test-all-target="button"]')).to be_nil
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

      it "renders the auto-balance toggle and warning for API-key runners without a monthly budget" do
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
        user.runners.create!(
          runner_key: "opencode",
          auth_type: "api_key",
          provider_api_key: api_key,
          enabled_for_agent_runs: true,
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
        )
        user.settings.update!(auto_weight_enabled: true)

        get runners_path

        expect(response.body).to include("Auto-balance weights based on usage quotas")
        expect(response.body).to include("has no monthly budget set. Its weight will not be auto-balanced.")
        expect(response.body).to match(/name="user_setting\[runner_weights\]\[[0-9]+\]".*disabled/m)
      end

      # @spec RUNNERS-INDEX-004
      it "omits the Rate Limits column while keeping usage details rate-limit counts" do
        runner = user.runners.find_by!(runner_key: "claude")
        allow(Runners::UsageStats).to receive(:call).and_return(
          runner.routing_key => {
            runs_7d: 3,
            cost_cents_7d: 250,
            tokens_7d: 1_500,
            fallback_total: 0,
            fallback_rate: 0,
            fallback_switched: 0,
            rate_limit_events_7d: 4
          }
        )

        get runners_path

        expect(runners_table_headers).not_to include("Rate Limits")
        expect(response.body).to include("Runner Usage Details")
        expect(response.body).to include("4")
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

      # @spec RUNNER-QUOTA-002
      it "shows fresh proactive quota details for supported runners" do
        state = user.runner_states.find_or_create_by!(runner_name: "claude")
        state.record_quota_status!(
          remaining: 700,
          limit: 1000,
          reset_at: 2.hours.from_now,
          unit: "tokens",
          available: true,
          source: "provider",
          checked_at: 3.minutes.ago
        )

        get runners_path

        expect(response.body).to include("70%")
        expect(response.body).to include("700 / 1,000")
        expect(response.body).to include("tokens")
        expect(response.body).to include("checked")
        expect(response.body).to include("resets")
      end

      # @spec RUNNER-QUOTA-002
      it "shows reactive-only fallback messaging when no upstream quota API is available" do
        state = user.runner_states.find_or_create_by!(runner_name: "claude")
        state.record_quota_status!(
          remaining: nil,
          limit: nil,
          reset_at: nil,
          unit: "tokens",
          available: false,
          source: "provider_unsupported",
          checked_at: 1.minute.ago
        )

        get runners_path

        expect(response.body).to include("Reactive only")
        expect(response.body).to include("No upstream quota API for this runner.")
      end
    end
  end

  describe "PATCH /runners/settings" do
    before do
      sign_in user
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor codex])
    end

    it "updates runner priority settings from the providers page" do
      cursor = user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true)
      codex = user.runners.create!(runner_key: "codex", enabled_for_agent_runs: false, enabled_for_fallback: true)
      claude = user.runners.find_by!(runner_key: "claude")

      patch settings_runners_path, params: {
        user_setting: {
          default_agent_runner: "cursor",
          default_agent_runners_by_goal: { create_pr: "cursor", review: "claude" },
          fallback_enabled: true,
          fallback_runners: %w[claude codex].to_json
        }
      }

      expect(response).to redirect_to(runners_path)
      settings = user.reload.settings
      expect(settings.default_agent_runner).to eq(cursor.routing_key)
      expect(settings.default_agent_runners_by_goal).to eq("create_pr" => cursor.routing_key, "review" => claude.routing_key)
      expect(settings.fallback_enabled).to be(true)
      expect(settings.fallback_runners).to eq([ claude.routing_key, codex.routing_key ])
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
      user.runners.create!(runner_key: "codex", enabled_for_agent_runs: true, enabled_for_fallback: true)

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
      expect(user.runners.find_by(runner_key: "codex").enabled_for_fallback).to be(false)
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

    it "persists auto_weight_enabled and enqueues an immediate rebalance when enabling it" do
      allow(RunnerQuotaBalanceJob).to receive(:perform_later)

      patch settings_runners_path, params: {
        user_setting: {
          auto_weight_enabled: "1",
          fallback_enabled: false,
          fallback_runners: [].to_json
        }
      }

      expect(response).to redirect_to(runners_path)
      expect(user.reload.settings.auto_weight_enabled).to be(true)
      expect(RunnerQuotaBalanceJob).to have_received(:perform_later).with(user.id)
    end

    it "ignores submitted manual weights while auto-weighting is enabled" do
      cursor = user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true, weight: 2)

      patch settings_runners_path, params: {
        user_setting: {
          auto_weight_enabled: "1",
          runner_weights: { cursor.id.to_s => "9" },
          fallback_enabled: false,
          fallback_runners: [].to_json
        }
      }

      expect(response).to redirect_to(runners_path)
      expect(cursor.reload.weight).to eq(2)
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
    before do
      sign_in user
      # Runner.direct_outbound_config_models_must_exist_in_catalog rejects direct-outbound
      # API-key runners whose model id is not present in the LlmModel catalog, so seed the
      # model ids used by post-runners-path params in this spec.
      KnownDirectOutboundModels.seed_model(model_id: "moonshotai/kimi-k2-0905", provider: "openrouter")
      KnownDirectOutboundModels.seed_model(model_id: "glm-5.1", provider: "inception")
    end

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

      post runners_path, params: { runner: { runner_key: "codex", enabled_for_agent_runs: true, enabled_for_fallback: true } }

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

    # @spec DIRECT-OUTBOUND-CATALOG-008
    it "persists only the model config for OpenCode and derives the provider from the API key" do
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
              model: "moonshotai/kimi-k2-0905"
            }
          }
        }
      }

      expect(response).to redirect_to(runners_path)
      runner = user.runners.find_by!(runner_key: "opencode", auth_type: "api_key")
      expect(runner.opencode_api_provider).to eq("openrouter")
      expect(runner.opencode_model_id).to eq("moonshotai/kimi-k2-0905")
      expect(runner.config).to eq("opencode" => { "model" => "moonshotai/kimi-k2-0905" })
    end

    # @spec FREE-MODEL-RUNNER-002
    it "creates an openrouter_free runner with default free tier mappings and suggested flags" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
      seed_openrouter_synced_free_models
      post_create_openrouter_free_runner(api_key:)
      expect(response).to redirect_to(runners_path)
      runner = user.runners.find_by!(runner_key: "openrouter_free", auth_type: "api_key")
      expect(runner.tier_model_ids).to eq(
        "low" => "free-low",
        "mid" => "free-mid",
        "high" => "free-high"
      )
      expect(runner.fallback_role).to eq("rate_limit_fallback")
      expect(runner.enabled_for_agent_runs).to be(true)
      expect(runner.enabled_for_chat).to be(true)
      expect(runner.enabled_for_fallback).to be(true)
    end

    # @spec FREE-MODEL-RUNNER-003
    it "preserves explicit openrouter_free settings supplied by the user" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
      seed_openrouter_synced_free_models
      create_free_model_override
      post_create_openrouter_free_runner(api_key:, runner_attrs: explicit_openrouter_free_runner_attrs)

      expect(response).to redirect_to(runners_path)
      expect_openrouter_free_runner_overrides(
        user.runners.find_by!(runner_key: "openrouter_free", auth_type: "api_key")
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

    it "accepts glm-5.2 for z.ai coding-plan KiloCode runners when the catalog is seeded" do
      api_key = create(:provider_api_key, user: user, api_service_type: "zai_coding")
      KnownDirectOutboundModels.seed_model(model_id: "glm-5.2", provider: "zai_coding")

      post runners_path, params: {
        runner: direct_outbound_runner_params(
          runner_key: "kilocode",
          api_key_id: api_key.id,
          model: "glm-5.2"
        )
      }

      expect(response).to redirect_to(runners_path)
      runner = user.runners.find_by!(runner_key: "kilocode", auth_type: "api_key")
      expect(runner.kilocode_api_provider).to eq("zai_coding")
      expect(runner.kilocode_model_id).to eq("glm-5.2")
    end

    it "upserts a missing catalog model as a manual row for KiloCode direct-outbound saves" do
      api_key = create(:provider_api_key, user: user, api_service_type: "zai_coding")

      post runners_path, params: {
        runner: direct_outbound_runner_params(
          runner_key: "kilocode",
          api_key_id: api_key.id,
          model: "glm-5.2"
        )
      }

      expect(response).to redirect_to(runners_path)
      runner = user.runners.find_by!(runner_key: "kilocode", auth_type: "api_key")
      expect(runner.kilocode_model_id).to eq("glm-5.2")
      expect(LlmModel.find_by(model_id: "glm-5.2")).to have_attributes(
        provider: "zai_coding",
        catalog_source: "manual"
      )
    end

    it "accepts glm-5.2 for z.ai coding-plan OpenCode runners when the catalog is seeded" do
      api_key = create(:provider_api_key, user: user, api_service_type: "zai_coding")
      KnownDirectOutboundModels.seed_model(model_id: "glm-5.2", provider: "zai_coding")

      post runners_path, params: {
        runner: direct_outbound_runner_params(
          runner_key: "opencode",
          api_key_id: api_key.id,
          model: "glm-5.2"
        )
      }

      expect(response).to redirect_to(runners_path)
      runner = user.runners.find_by!(runner_key: "opencode", auth_type: "api_key")
      expect(runner.opencode_api_provider).to eq("zai_coding")
      expect(runner.opencode_model_id).to eq("glm-5.2")
    end

    it "upserts a missing catalog model as a manual row for OpenCode direct-outbound saves" do
      api_key = create(:provider_api_key, user: user, api_service_type: "zai_coding")

      post runners_path, params: {
        runner: direct_outbound_runner_params(
          runner_key: "opencode",
          api_key_id: api_key.id,
          model: "glm-5.2"
        )
      }

      expect(response).to redirect_to(runners_path)
      runner = user.runners.find_by!(runner_key: "opencode", auth_type: "api_key")
      expect(runner.opencode_model_id).to eq("glm-5.2")
      expect(LlmModel.find_by(model_id: "glm-5.2")).to have_attributes(
        provider: "zai_coding",
        catalog_source: "manual"
      )
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
              model: ""
            }
          }
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must include an OpenCode model id")
    end

    # @spec MODEL-POLICY-008 MODEL-POLICY-011
    it "creates a disabled free-policy OpenCode runner without a model id when the API provider is openrouter" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")

      post runners_path, params: { runner: free_policy_runner_params(api_key_id: api_key.id) }

      expect(response).to redirect_to(runners_path)
      runner = user.runners.find_by!(runner_key: "opencode", auth_type: "api_key")
      expect(runner.opencode_model_policy).to eq("free")
      expect(runner.opencode_model_id).to be_nil
      expect(runner).not_to be_enabled_for_agent_runs
      expect(runner).not_to be_enabled_for_fallback
      expect(runner).not_to be_enabled_for_chat
    end

    # @spec MODEL-POLICY-011
    it "rejects creating an enabled free-policy OpenCode runner until free-policy dispatch lands" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")

      post runners_path, params: { runner: free_policy_runner_params(api_key_id: api_key.id, enabled: true) }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("OpenCode free model policy cannot be enabled until free-policy dispatch lands")
      expect(user.runners.where(runner_key: "opencode", auth_type: "api_key")).not_to exist
    end

    # @spec MODEL-POLICY-002 MODEL-POLICY-008
    it "rejects an OpenCode free policy on a non-openrouter API provider" do
      api_key = create(:provider_api_key, user: user, api_service_type: "inception")

      post runners_path, params: { runner: free_policy_runner_params(api_key_id: api_key.id, api_provider: "inception") }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("OpenCode free model policy requires the OpenRouter API provider")
    end

    # @spec DIRECT-OUTBOUND-CATALOG-008
    it "persists only the model config for Oh My Pi and derives the provider from the API key" do
      KnownDirectOutboundModels.seed_model(model_id: "deepseek-chat", provider: "deepseek")
      api_key = create(:provider_api_key, user: user, api_service_type: "deepseek")

      post runners_path, params: {
        runner: direct_outbound_runner_params(
          runner_key: "omp",
          api_key_id: api_key.id,
          model: "deepseek-chat"
        )
      }

      expect(response).to redirect_to(runners_path)
      runner = user.runners.find_by!(runner_key: "omp", auth_type: "api_key")
      expect(runner.omp_api_provider).to eq("deepseek")
      expect(runner.omp_model_id).to eq("deepseek-chat")
      expect(runner.config).to eq("omp" => { "model" => "deepseek-chat" })
      expect(runner.display_name).to eq("Oh My Pi deepseek-chat (API Key)")
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

    it "offers kilocode in the API-key runner list when a compatible key exists" do
      create(:provider_api_key, user: user, api_service_type: "openrouter", name: "OpenRouter")
      allow(RunnerSupport).to receive(:addable_runner_keys).and_return(%w[claude kilocode])

      get new_runner_path(form_variant: "api_key")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('value="api_key"')
      expect(response.body).to include('id="runner_runner_key_api_key"')
      expect(response.body).to include('option value="kilocode"')
    end

    it "offers Oh My Pi in the API-key runner list when a compatible key exists" do
      create(:provider_api_key, user: user, api_service_type: "deepseek", name: "DeepSeek")
      allow(RunnerSupport).to receive(:addable_runner_keys).and_return(%w[claude omp])

      get new_runner_path(form_variant: "api_key")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('option value="omp"')
      expect(response.body).to include("Oh My Pi")
    end

    # @spec DIRECT-OUTBOUND-CATALOG-006
    it "groups API keys by provider and omits direct-outbound api_provider selects from the API-key form" do
      create(:provider_api_key, user: user, api_service_type: "openrouter", name: "OpenRouter A")
      create(:provider_api_key, user: user, api_service_type: "openrouter", name: "OpenRouter B")
      create(:provider_api_key, user: user, api_service_type: "anthropic", name: "Anthropic Key")
      create(:llm_model, model_id: "moonshotai/kimi-k2-0905", provider: "openrouter", display_name: "Kimi K2")
      create(:llm_model, model_id: "claude-sonnet-4-20250514", provider: "anthropic", display_name: "Claude Sonnet 4")
      allow(RunnerSupport).to receive(:addable_runner_keys).and_return(%w[opencode])

      get new_runner_path(form_variant: "api_key", runner_key: "opencode")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<optgroup label="Anthropic (1 key)">')
      expect(response.body).to include('<optgroup label="OpenRouter (2 keys)">')
      expect(response.body).not_to include('name="runner[config][opencode][api_provider]"')
      expect(response.body).to include('name="runner[config][opencode][model]"')
    end

    # @spec DIRECT-OUTBOUND-CATALOG-008
    it "does not preselect a provider's models before an API key is chosen on a new OpenCode runner" do
      create(:provider_api_key, user: user, api_service_type: "openrouter", name: "OpenRouter")
      create(:llm_model, model_id: "moonshotai/kimi-k2-0905", provider: "openrouter", display_name: "Kimi K2")
      allow(RunnerSupport).to receive(:addable_runner_keys).and_return(%w[opencode])

      get new_runner_path(form_variant: "api_key", runner_key: "opencode")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-current-service-type=""')
      expect(response.body).to include('<option value="">Select an API key first</option>')
      expect(response.body).not_to include('<option value="moonshotai/kimi-k2-0905"')
    end

    it "defaults back to subscription when the requested runner already has an active managed credential" do
      create(:provider_api_key, user: user, api_service_type: "anthropic", name: "Anthropic")
      create(:runner_credential, account: user.account, created_by: user, runner_key: "claude", long_lived: true)

      get new_runner_path(form_variant: "api_key", runner_key: "claude")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('value="subscription" checked="checked"')
      expect(response.body).not_to include('value="api_key" checked="checked"')
      expect(response.body).to include("Paid prefers it over host-mounted Claude auth")
    end

    it "hides openrouter_free once the user already has one configured" do
      create(:provider_api_key, user: user, api_service_type: "openrouter", name: "OpenRouter")
      free_model = create(:llm_model, model_id: "free-low", provider: "openrouter", tier: "low", pricing_tier: "free")
      user.runners.create!(
        runner_key: "openrouter_free",
        auth_type: "api_key",
        provider_api_key: user.provider_api_keys.first,
        tier_model_ids: LlmModel::TIERS.index_with { free_model.model_id }
      )
      allow(RunnerSupport).to receive(:addable_runner_keys).and_return(%w[claude openrouter_free kilocode])

      get new_runner_path(form_variant: "api_key")

      expect(response).to have_http_status(:ok)
      # Single-instance runner is hidden once added...
      expect(response.body).not_to include('option value="openrouter_free"')
      # ...but other API-key runners remain available.
      expect(response.body).to include('option value="kilocode"')
    end

    it "keeps offering duplicate-capable API-key runners after one is added" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter", name: "OpenRouter")
      create(:llm_model, model_id: "moonshotai/kimi-k2-0905", provider: "openrouter", tier: "mid")
      user.runners.create!(
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { opencode: { api_provider: "openrouter", model: "moonshotai/kimi-k2-0905" } },
        enabled_for_agent_runs: true,
        enabled_for_fallback: true
      )
      allow(RunnerSupport).to receive(:addable_runner_keys).and_return(%w[claude opencode])

      get new_runner_path(form_variant: "api_key")

      expect(response).to have_http_status(:ok)
      # opencode allows legitimate duplicates, so it must still appear even
      # though the user already has one configured.
      expect(response.body).to include('option value="opencode"')
    end

    it "keeps the index Add Runner CTA available while only the single-instance runner is hidden" do
      create(:provider_api_key, user: user, api_service_type: "openrouter", name: "OpenRouter")
      free_model = create(:llm_model, model_id: "free-low", provider: "openrouter", tier: "low", pricing_tier: "free")
      user.runners.create!(
        runner_key: "openrouter_free",
        auth_type: "api_key",
        provider_api_key: user.provider_api_keys.first,
        tier_model_ids: LlmModel::TIERS.index_with { free_model.model_id }
      )
      # openrouter_free is hidden (single-instance, already added) but kilocode
      # is a duplicate-capable API-key runner with a compatible key, so the
      # "Add Runner" CTA must remain instead of showing "No More Runners Yet".
      allow(RunnerSupport).to receive(:addable_runner_keys).and_return(%w[claude openrouter_free kilocode])

      get runners_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Add Runner")
      expect(response.body).not_to include("No More Runners Yet")
    end

    # @spec FREE-MODEL-RUNNER-004
    # @spec FREE-MODEL-RUNNER-005
    # @spec FREE-MODEL-RUNNER-006
    it "prefills openrouter_free setup from the catalog link with free-model guidance" do
      create(:provider_api_key, user: user, api_service_type: "openrouter", name: "OpenRouter")
      seed_free_runner_form_models
      allow(RunnerSupport).to receive(:addable_runner_keys).and_return(%w[claude openrouter_free])

      get new_runner_path(form_variant: "api_key", runner_key: "openrouter_free")

      expect(response).to have_http_status(:ok)
      expect_free_runner_form_guidance(response.body)
    end
  end

  describe "PATCH /runners/:id" do
    before do
      sign_in user
      # Seed direct-outbound model ids used by patch-runner-path params in this spec so
      # the seeded-catalog lookup path is exercised (matches the test factory fixture).
      KnownDirectOutboundModels.seed_model(model_id: "moonshotai/kimi-k2-0905", provider: "openrouter")
    end

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

    it "renders the monthly token budget field for API-key runners" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
      runner = user.runners.create!(
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
      )

      get edit_runner_path(runner)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Monthly Token Budget")
      expect(response.body).to include("Leave empty for unlimited")
    end

    # @spec DIRECT-OUTBOUND-CATALOG-006
    it "renders OpenCode model inputs without an api_provider select for non-OpenCode runners" do
      runner = user.runners.find_by!(runner_key: "claude")

      get edit_runner_path(runner)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('name="runner[config][opencode][api_provider]"')
      expect(response.body).to match(/name="runner\[config\]\[opencode\]\[model\]".*disabled/m)
    end

    # @spec DIRECT-OUTBOUND-CATALOG-006
    it "renders Oh My Pi model inputs for persisted OMP API-key runners without an api_provider select" do
      KnownDirectOutboundModels.seed_model(model_id: "deepseek-chat", provider: "deepseek")
      api_key = create(:provider_api_key, user: user, api_service_type: "deepseek")
      runner = user.runners.create!(
        runner_key: "omp",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "omp" => { "api_provider" => "deepseek", "model" => "deepseek-chat" } }
      )

      get edit_runner_path(runner)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Oh My Pi Model")
      expect(response.body).not_to include('name="runner[config][omp][api_provider]"')
      expect(response.body).to include('name="runner[config][omp][model]"')
    end

    # @spec DIRECT-OUTBOUND-CATALOG-009
    it "preserves a required OpenCode model that has since been deactivated in the catalog" do
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
      runner = user.runners.create!(
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "model" => "retired/model-x" } }
      )
      LlmModel.find_by!(model_id: "retired/model-x").update!(active: false)

      get edit_runner_path(runner)

      expect(response).to have_http_status(:ok)
      expect(response.body).to match(%r{<option value="retired/model-x"\s+selected>})
    end

    # @spec DIRECT-OUTBOUND-CATALOG-009
    it "preserves an optional Pi model that has since been deactivated in the catalog" do
      api_key = create(:provider_api_key, user: user, api_service_type: "deepseek")
      runner = user.runners.create!(
        runner_key: "pi",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "pi" => { "model" => "deepseek-legacy" } }
      )
      LlmModel.find_by!(model_id: "deepseek-legacy").update!(active: false)

      get edit_runner_path(runner)

      expect(response).to have_http_status(:ok)
      expect(response.body).to match(/<option value="deepseek-legacy"\s+selected>/)
    end

    # @spec DIRECT-OUTBOUND-CATALOG-010
    it "renders a manual model entry field when the derived provider has no catalog rows and no saved model" do
      api_key = create(:provider_api_key, user: user, api_service_type: "mistral")
      runner = user.runners.create!(
        runner_key: "pi",
        auth_type: "api_key",
        provider_api_key: api_key
      )

      get edit_runner_path(runner)

      expect(response).to have_http_status(:ok)
      manual_input = response.body[/<input[^>]*name="runner\[config\]\[pi\]\[model\]"[^>]*data-runner-form-target="dynamicModelManualInput"[^>]*>/]
      select_tag = response.body[/<select[^>]*name="runner\[config\]\[pi\]\[model\]"[^>]*>/m]
      expect(manual_input).to be_present
      expect(manual_input).not_to include("disabled")
      expect(select_tag).to include("disabled")
    end

    # @spec MODEL-POLICY-FORM-001 MODEL-POLICY-FORM-002 MODEL-POLICY-FORM-006
    context "when runner_model_policy_form is enabled" do
      before { FeatureFlags.enable!(:runner_model_policy_form) }

      # The runner-key-specific Model <select> node, parsed with Nokogiri so
      # assertions read the rendered <option>s rather than the raw HTML —
      # the select's own data-model-entries-by-service-type attribute value
      # contains a literal ">" (from "change->runner-form#...") that breaks
      # naive [^>]* tag-boundary regexes, and it intentionally carries every
      # service type's entries (Free included) up front for the JS re-render,
      # so a substring check against the raw body would see the embedded
      # JSON for keys/providers that are not currently selected.
      def catalog_select_node(body, runner_key)
        Nokogiri::HTML(body).at_css("select#runner_config_#{runner_key}_model")
      end

      it "renders the Free policy option, catalog rows, and the Custom sentinel for OpenCode on an OpenRouter key" do
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
        LlmModel.find_by!(model_id: "moonshotai/kimi-k2-0905").update!(display_name: "Kimi K2", family: "Kimi")
        runner = user.runners.create!(
          runner_key: "opencode",
          auth_type: "api_key",
          provider_api_key: api_key,
          config: { "opencode" => { "model" => "moonshotai/kimi-k2-0905" } }
        )

        get edit_runner_path(runner)

        expect(response).to have_http_status(:ok)
        select = catalog_select_node(response.body, "opencode")
        expect(select.at_css('option[value="free"]').text).to eq("OpenRouter Free (curated, tiered)")
        expect(select.at_css('option[value="custom"]').text).to eq("Custom model ID…")
        selected = select.at_css("option[selected]")
        expect(selected["value"]).to eq("moonshotai/kimi-k2-0905")
        expect(selected.text).to eq("Kimi K2")
        expect(response.body).to include('name="runner[config][opencode][model_policy]"')
        expect(response.body).not_to include('name="runner[config][opencode][api_provider]"')
      end

      it "omits the Free policy option for OpenCode on a non-OpenRouter key" do
        api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
        create(:llm_model, model_id: "claude-sonnet-4-20250514", provider: "anthropic", display_name: "Claude Sonnet 4")
        runner = user.runners.create!(
          runner_key: "opencode",
          auth_type: "api_key",
          provider_api_key: api_key,
          config: { "opencode" => { "model" => "claude-sonnet-4-20250514" } }
        )

        get edit_runner_path(runner)

        expect(response).to have_http_status(:ok)
        select = catalog_select_node(response.body, "opencode")
        expect(select.at_css('option[value="free"]')).to be_nil
        selected = select.at_css("option[selected]")
        expect(selected["value"]).to eq("claude-sonnet-4-20250514")
      end

      # @spec MODEL-POLICY-FORM-004
      it "preselects the Free sentinel and drops the model select's name for a free-policy OpenCode runner" do
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
        runner = user.runners.create!(
          runner_key: "opencode",
          auth_type: "api_key",
          provider_api_key: api_key,
          enabled_for_agent_runs: false,
          enabled_for_chat: false,
          enabled_for_fallback: false,
          config: { "opencode" => { "model_policy" => "free" } }
        )

        get edit_runner_path(runner)

        expect(response).to have_http_status(:ok)
        select = catalog_select_node(response.body, "opencode")
        selected = select.at_css("option[selected]")
        expect(selected["value"]).to eq("free")
        expect(select["name"]).to be_nil
        policy_field = Nokogiri::HTML(response.body).at_css('input[data-runner-form-target="policyModelPolicyField"]')
        expect(policy_field["value"]).to eq("free")
      end

      # @spec MODEL-POLICY-FORM-003
      it "preselects Custom and prefills the manual input when the current model id is no longer active in the catalog" do
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
        runner = user.runners.create!(
          runner_key: "opencode",
          auth_type: "api_key",
          provider_api_key: api_key,
          config: { "opencode" => { "model" => "moonshotai/kimi-k2.6" } }
        )
        LlmModel.find_by!(model_id: "moonshotai/kimi-k2.6").update!(active: false)

        get edit_runner_path(runner)

        expect(response).to have_http_status(:ok)
        select = catalog_select_node(response.body, "opencode")
        selected = select.at_css("option[selected]")
        expect(selected["value"]).to eq("custom")
        expect(select["name"]).to be_nil
        manual_input = Nokogiri::HTML(response.body).at_css("#runner_config_opencode_model_manual")
        expect(manual_input["name"]).to eq("runner[config][opencode][model]")
        expect(manual_input["value"]).to eq("moonshotai/kimi-k2.6")
      end

      # @spec MODEL-POLICY-FORM-005
      it "does not render a model_policy field or the Free option for KiloCode" do
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
        runner = user.runners.create!(
          runner_key: "kilocode",
          auth_type: "api_key",
          provider_api_key: api_key,
          config: { "kilocode" => { "model" => "moonshotai/kimi-k2-0905" } }
        )

        get edit_runner_path(runner)

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('name="runner[config][kilocode][model_policy]"')
        expect(catalog_select_node(response.body, "kilocode").at_css('option[value="free"]')).to be_nil
      end
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
        allow(Runners::TestAgent).to receive(:call).with(runner: runner).and_return(result)

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
        allow(Runners::TestAgent).to receive(:call).with(runner: runner).and_return(result)

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
        allow(Runners::TestAgent).to receive(:call).with(runner: runner).and_return(result)

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

  def seed_openrouter_synced_free_models
    create(:llm_model, model_id: "free-low", provider: "deepseek", tier: "low", pricing_tier: "free", capability_score: 4.0,
      catalog_source: "openrouter_sync")
    create(:llm_model, model_id: "free-mid", provider: "moonshotai", tier: "mid", pricing_tier: "free", capability_score: 6.0,
      catalog_source: "openrouter_sync")
    create(:llm_model, model_id: "free-high", provider: "qwen", tier: "high", pricing_tier: "free", capability_score: 8.0,
      catalog_source: "openrouter_sync")
  end

  def create_free_model_override
    create(:llm_model, model_id: "free-low-alt", provider: "deepseek", tier: "low", pricing_tier: "free", capability_score: 3.0,
      catalog_source: "openrouter_sync")
  end

  def explicit_openrouter_free_runner_attrs
    {
      fallback_role: "standard",
      enabled_for_agent_runs: false,
      enabled_for_chat: false,
      enabled_for_fallback: false,
      tier_model_ids: {
        low: "free-low-alt",
        mid: "free-mid",
        high: "free-high"
      }
    }
  end

  def expect_openrouter_free_runner_overrides(runner)
    aggregate_failures do
      expect(runner.fallback_role).to eq("standard")
      expect(runner.enabled_for_agent_runs).to be(false)
      expect(runner.enabled_for_chat).to be(false)
      expect(runner.enabled_for_fallback).to be(false)
      expect(runner.tier_model_ids).to eq(
        "low" => "free-low-alt",
        "mid" => "free-mid",
        "high" => "free-high"
      )
    end
  end

  def seed_free_runner_form_models
    create(:llm_model, model_id: "high-free", provider: "deepseek", tier: "high", pricing_tier: "free", capability_score: 8.0,
      catalog_source: "openrouter_sync")
    create(:llm_model, model_id: "high-free-below-bar", provider: "deepseek", tier: "high", pricing_tier: "free", capability_score: 6.0,
      catalog_source: "openrouter_sync", metadata: { "below_quality_bar" => true })
    create(:llm_model, model_id: "mid-free", provider: "moonshotai", tier: "mid", pricing_tier: "free", capability_score: 6.0,
      catalog_source: "openrouter_sync")
    create(:llm_model, model_id: "low-free", provider: "qwen", tier: "low", pricing_tier: "free", capability_score: 4.0,
      catalog_source: "openrouter_sync")
  end

  def expect_free_runner_form_guidance(body)
    aggregate_failures do
      expect(body).to include("OpenRouter Free")
      expect(body).to include("Free Model Configuration")
      expect(body).to include("Data classification routing")
      expect(body).to include("~20 free requests/day without OpenRouter credits")
      expect(body).to include("High tier free models")
      expect(body).to include("Below quality bar")
      expect(body).to include('value="high-free" selected')
      expect(body).to include('value="mid-free" selected')
      expect(body).to include('value="low-free" selected')
    end
  end

  def post_create_openrouter_free_runner(api_key:, runner_attrs: {})
    post runners_path, params: {
      runner: {
        runner_key: "openrouter_free",
        auth_type: "api_key",
        provider_api_key_id: api_key.id,
        enabled_for_agent_runs: true,
        enabled_for_fallback: true
      }.deep_merge(runner_attrs)
    }
  end
end
