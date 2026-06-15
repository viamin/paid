# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunnerSmokeHelpers do
  around do |example|
    original = ENV["PAID_SMOKE_SCENARIOS"]
    example.run
  ensure
    original ? ENV["PAID_SMOKE_SCENARIOS"] = original : ENV.delete("PAID_SMOKE_SCENARIOS")
  end

  describe ".scenario_names_from_env" do
    it "defaults to the current-enabled preset" do
      ENV.delete("PAID_SMOKE_SCENARIOS")
      allow(described_class).to receive(:configured_scenario_names).and_return(%w[opencode-minimax pi-minimax])

      expect(described_class.scenario_names_from_env).to eq(%w[
        claude-subscription
        codex-subscription
        copilot-subscription
        kilocode-zai
        opencode-openrouter
        kilocode-inception
        opencode-minimax
        pi-minimax
      ])
    end

    it "expands preset names from the environment" do
      ENV["PAID_SMOKE_SCENARIOS"] = "current-enabled"
      allow(described_class).to receive(:configured_scenario_names).and_return(%w[opencode-minimax])

      expect(described_class.scenario_names_from_env).to eq(described_class.current_enabled_scenario_names)
    end

    it "preserves duplicate scenario names for distinct matrix entries" do
      ENV["PAID_SMOKE_SCENARIOS"] = "kilocode-zai,kilocode-inception"

      expect(described_class.scenario_names_from_env).to eq(%w[kilocode-zai kilocode-inception])
    end
  end

  describe ".scenario_for" do
    it "includes the expected built-in default models for current enabled api-key scenarios" do
      expect(described_class.scenario_for("kilocode-zai").default_model).to eq("glm-5.1")
      expect(described_class.scenario_for("opencode-openrouter").default_model).to eq("moonshotai/kimi-k2-0905")
      expect(described_class.scenario_for("kilocode-inception").default_model).to eq("mercury-2")
      expect(described_class.scenario_for("opencode-minimax").default_model).to eq("MiniMax-M2.7")
      expect(described_class.scenario_for("pi-deepseek").default_model).to eq("deepseek-chat")
      expect(described_class.scenario_for("pi-minimax").default_model).to eq("MiniMax-M2.7")
    end

    it "raises a helpful error for unknown names" do
      expect { described_class.scenario_for("unknown-runner") }
        .to raise_error(RunnerSmokeHelpers::ScenarioUnavailableError, /Unknown runner smoke scenario/)
    end
  end

  describe ".build_direct_outbound_runner!", :db do
    let(:account) { create(:account, slug: "runner-smoke-helpers-account") }
    let(:user) { create(:user, account: account, email: "runner-smoke-helpers@example.com") }
    let(:scenario) { described_class.scenario_for("opencode-openrouter") }

    it "prefers the scenario default model over the development-db fallback model" do
      allow(described_class).to receive(:development_runner_info_for).with(scenario).and_return(
        { "model" => "moonshotai/kimi-k2-0905", "api_key" => "sk-test" }
      )

      runner = described_class.build_direct_outbound_runner!(user: user, scenario: scenario)

      expect(runner.opencode_model_id).to eq("moonshotai/kimi-k2-0905")
    end

    it "builds Pi DeepSeek runners through the shared direct-outbound path" do
      pi_scenario = described_class.scenario_for("pi-deepseek")
      allow(described_class).to receive(:development_runner_info_for).with(pi_scenario).and_return(
        { "api_key" => "sk-deepseek-test" }
      )

      runner = described_class.build_direct_outbound_runner!(user: user, scenario: pi_scenario)

      expect(runner.runner_key).to eq("pi")
      expect(runner.pi_api_provider).to eq("deepseek")
      expect(runner.pi_model_id).to eq("deepseek-chat")
      expect(runner.provider_api_key.api_service_type).to eq("deepseek")
    end

    it "builds MiniMax runners with the Anthropic env-var backed service type" do
      minimax_scenario = described_class.scenario_for("opencode-minimax")
      allow(described_class).to receive(:development_runner_info_for).with(minimax_scenario).and_return(
        { "api_key" => "sk-minimax-test" }
      )

      runner = described_class.build_direct_outbound_runner!(user: user, scenario: minimax_scenario)

      expect(runner.runner_key).to eq("opencode")
      expect(runner.opencode_api_provider).to eq("minimax")
      expect(runner.opencode_model_id).to eq("MiniMax-M2.7")
      expect(runner.provider_api_key.api_service_type).to eq("minimax")
    end

    it "builds Pi Google runners with the Pi-specific provider config" do
      pi_scenario = described_class::Scenario.new(
        name: "pi-google",
        runner_key: "pi",
        auth_type: "api_key",
        api_provider: "google",
        model_env: "PAID_SMOKE_PI_GOOGLE_MODEL",
        default_model: "gemini-2.5-pro",
        label: "Pi with Google API key"
      )
      allow(described_class).to receive(:development_runner_info_for).with(pi_scenario).and_return(
        { "api_key" => "sk-gemini-test" }
      )

      runner = described_class.build_direct_outbound_runner!(user: user, scenario: pi_scenario)

      expect(runner.runner_key).to eq("pi")
      expect(runner.pi_api_provider).to eq("google")
      expect(runner.pi_model_id).to eq("gemini-2.5-pro")
      expect(runner.provider_api_key.api_service_type).to eq("google")
    end

    it "rejects providers that are unsupported for the selected runner" do
      pi_scenario = described_class::Scenario.new(
        name: "pi-zai-coding",
        runner_key: "pi",
        auth_type: "api_key",
        api_provider: "zai_coding",
        model_env: "PAID_SMOKE_PI_ZAI_CODING_MODEL",
        default_model: "glm-5.2",
        label: "Pi with z.ai coding API key"
      )

      expect { described_class.build_direct_outbound_runner!(user: user, scenario: pi_scenario) }
        .to raise_error(
          RunnerSmokeHelpers::ScenarioUnavailableError,
          /Unsupported pi api provider "zai_coding"/
        )
    end
  end

  describe ".api_key_env_var_for" do
    it "uses the Pi provider override for Google Gemini" do
      expect(described_class.api_key_env_var_for(runner_key: "pi", api_provider: "google"))
        .to eq("GEMINI_API_KEY")
    end

    it "uses the direct-outbound provider override for MiniMax" do
      expect(described_class.api_key_env_var_for(runner_key: "opencode", api_provider: "minimax"))
        .to eq("ANTHROPIC_API_KEY")
    end
  end

  describe ".current_enabled_scenario_names" do
    it "adds configured direct-outbound scenarios to the baseline preset" do
      allow(described_class).to receive(:configured_scenario_names).and_return(%w[opencode-minimax pi-minimax])

      expect(described_class.current_enabled_scenario_names).to eq(%w[
        claude-subscription
        codex-subscription
        copilot-subscription
        kilocode-zai
        opencode-openrouter
        kilocode-inception
        opencode-minimax
        pi-minimax
      ])
    end

    it "does not duplicate scenarios already present in the baseline preset" do
      allow(described_class).to receive(:configured_scenario_names).and_return(%w[kilocode-zai opencode-openrouter])

      expect(described_class.current_enabled_scenario_names).to eq(described_class::DEFAULT_SCENARIO_NAMES)
    end
  end
end
