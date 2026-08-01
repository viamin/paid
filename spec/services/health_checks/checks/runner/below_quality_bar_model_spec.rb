# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::Runner::BelowQualityBarModel do
  it "returns a finding when a tier resolves to a below-quality-bar model" do
    model = create(:llm_model, :openai, :below_quality_bar, model_id: "gpt-low-bar", tier: "high")
    runner = create_runner_with_model(model, tier: "high")

    expect(described_class.call(runner)).to contain_exactly(
      have_attributes(
        check: described_class.name,
        scope: :runner,
        severity: :warning,
        message: "Runner #{runner.display_name} resolves below-quality-bar model gpt-low-bar for high tier."
      )
    )
  end

  it "returns no findings when resolved models clear the quality bar" do
    model = create(:llm_model, :openai, model_id: "gpt-good-bar", tier: "high")
    runner = create_runner_with_model(model, tier: "high")

    expect(described_class.call(runner)).to eq([])
  end

  def create_runner_with_model(model, tier:)
    user = create(:user)
    api_key = create(:provider_api_key, user: user, api_service_type: "openai")
    create(
      :runner,
      :api_key,
      user: user,
      runner_key: "codex",
      provider_api_key: api_key,
      tier_model_ids: { tier => model.model_id }
    )
  end
end
