# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::ResolveTierModel do
  describe ".call" do
    let(:user) { create(:user) }
    let(:runner_key) { "codex" }
    let(:runner) do
      api_key = create(:runner_api_key, user: user, api_service_type: "openai")
      create(:runner, :api_key, user: user, runner_key: runner_key, provider_api_key: api_key, tier_models: {})
    end

    it "prefers the runner tier mapping" do
      runner.update!(tier_models: {
        "mid" => { "model_id" => "runner-mid", "provider_id" => 17 }
      })

      result = described_class.call(runner: runner, tier: "mid", user: user)

      expect(result).to have_attributes(
        model_id: "runner-mid",
        provider_id: 17,
        source: "runner"
      )
      expect(result).to be_success
    end

    it "falls back to the matching provider tier mapping" do
      provider_runner = Runner.new(runner_key: runner_key)
      create(
        :provider,
        user: user,
        provider_key: runner_key,
        auth_type: "subscription",
        tier_models: {
          "mid" => { "model_id" => "provider-mid", "provider_id" => 23 }
        }
      )

      result = described_class.call(runner: provider_runner, tier: "mid", user: user)

      expect(result).to have_attributes(
        model_id: "provider-mid",
        provider_id: 23,
        source: "provider"
      )
      expect(result).to be_success
    end

    it "falls back to the default tier model" do
      create(:llm_model, model_id: "default-mid", provider: "openai", tier: "mid", capability_score: 9.0)

      result = described_class.call(runner: runner, tier: "mid", user: user)

      expect(result).to have_attributes(
        model_id: "default-mid",
        provider_id: user.provider_for(runner)&.id,
        source: "default"
      )
      expect(result).to be_success
    end

    it "fails when no runner, provider, or default model is configured for the tier" do
      result = described_class.call(runner: runner, tier: "high", user: user)

      expect(result).to be_failure
      expect(result.error).to eq("no model configured for #{runner_key} at high")
    end
  end
end
