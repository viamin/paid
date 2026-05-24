# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::ResolveTierModel do
  describe ".call" do
    it "prefers the runner tier mapping over defaults" do
      runner = build(:runner, runner_key: "cursor", tier_models: {
        "mid" => { "model_id" => "sonnet-x", "provider_id" => 42 }
      })

      result = described_class.call(runner: runner, tier: "mid")

      expect(result).to have_attributes(
        success?: true,
        model_id: "sonnet-x",
        provider_id: 42,
        source: "runner"
      )
    end

    it "falls back to defaults when no explicit tier mapping exists" do
      create(:llm_model, model_id: "haiku-x", provider: "anthropic", tier: "low")
      runner = build(:runner, runner_key: "cursor")

      result = described_class.call(runner: runner, tier: "low")

      expect(result).to have_attributes(
        success?: true,
        model_id: "haiku-x",
        source: "default"
      )
    end

    it "fails when neither explicit nor default mapping resolves" do
      runner = build(:runner, runner_key: "opencode")

      result = described_class.call(runner: runner, tier: "high")

      expect(result).to be_failure
      expect(result.error).to include("no model configured")
    end
  end
end
