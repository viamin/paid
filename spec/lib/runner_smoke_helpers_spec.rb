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

      expect(described_class.scenario_names_from_env).to eq(%w[
        claude-subscription
        codex-subscription
        copilot-subscription
        kilocode-zai
        opencode-openrouter
        kilocode-inception
      ])
    end

    it "expands preset names from the environment" do
      ENV["PAID_SMOKE_SCENARIOS"] = "current-enabled"

      expect(described_class.scenario_names_from_env).to eq(described_class::PRESETS.fetch("current-enabled"))
    end

    it "preserves duplicate scenario names for distinct matrix entries" do
      ENV["PAID_SMOKE_SCENARIOS"] = "kilocode-zai,kilocode-inception"

      expect(described_class.scenario_names_from_env).to eq(%w[kilocode-zai kilocode-inception])
    end
  end

  describe ".scenario_for" do
    it "includes the expected built-in default models for current enabled api-key scenarios" do
      expect(described_class.scenario_for("kilocode-zai").default_model).to eq("glm-5.1")
      expect(described_class.scenario_for("opencode-openrouter").default_model).to eq("moonshotai/kimi-k2")
      expect(described_class.scenario_for("kilocode-inception").default_model).to eq("mercury-2")
    end

    it "raises a helpful error for unknown names" do
      expect { described_class.scenario_for("unknown-provider") }
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

      expect(runner.opencode_model_id).to eq("moonshotai/kimi-k2")
    end
  end
end
