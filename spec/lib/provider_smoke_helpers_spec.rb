# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProviderSmokeHelpers do
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
      expect { described_class.scenario_for("unknown-provider") }
        .to raise_error(ProviderSmokeHelpers::ScenarioUnavailableError, /Unknown provider smoke scenario/)
    end
  end

  describe ".build_direct_outbound_provider!", :db do
    let(:account) { create(:account, slug: "provider-smoke-helpers-account") }
    let(:user) { create(:user, account: account, email: "provider-smoke-helpers@example.com") }
    let(:scenario) { described_class.scenario_for("opencode-openrouter") }

    it "prefers the development-db model over the scenario default model" do
      allow(described_class).to receive(:development_provider_info_for).with(scenario).and_return(
        { "model" => "moonshotai/kimi-k2-0905", "api_key" => "sk-test" }
      )

      provider = described_class.build_direct_outbound_provider!(user: user, scenario: scenario)

      expect(provider.opencode_model_id).to eq("moonshotai/kimi-k2-0905")
    end

    it "builds Pi DeepSeek providers through the shared direct-outbound path" do
      scenario = described_class.scenario_for("pi-deepseek")
      allow(described_class).to receive(:development_provider_info_for).with(scenario).and_return(
        { "api_key" => "sk-deepseek-test" }
      )

      provider = described_class.build_direct_outbound_provider!(user: user, scenario: scenario)

      expect(provider.provider_key).to eq("pi")
      expect(provider.pi_api_provider).to eq("deepseek")
      expect(provider.pi_model_id).to eq("deepseek-chat")
      expect(provider.provider_api_key.api_service_type).to eq("deepseek")
    end

    it "builds MiniMax providers with the Anthropic env-var backed service type" do
      scenario = described_class.scenario_for("opencode-minimax")
      allow(described_class).to receive(:development_provider_info_for).with(scenario).and_return(
        { "api_key" => "sk-minimax-test" }
      )

      provider = described_class.build_direct_outbound_provider!(user: user, scenario: scenario)

      expect(provider.provider_key).to eq("opencode")
      expect(provider.opencode_api_provider).to eq("minimax")
      expect(provider.opencode_model_id).to eq("MiniMax-M2.7")
      expect(provider.provider_api_key.api_service_type).to eq("minimax")
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
