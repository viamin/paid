# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::Runner::InactiveModel do
  it "returns a finding when a tier resolves to an inactive model" do
    model = create(:llm_model, :openai, :inactive, model_id: "gpt-inactive", tier: "low")
    runner = create_runner_with_model(model, tier: "low")

    expect(described_class.call(runner)).to contain_exactly(
      have_attributes(
        check: described_class.name,
        scope: :runner,
        severity: :error,
        message: "Runner #{runner.display_name} resolves inactive model gpt-inactive for low tier."
      )
    )
  end

  it "returns no findings when resolved models are active" do
    model = create(:llm_model, :openai, model_id: "gpt-active", tier: "low")
    runner = create_runner_with_model(model, tier: "low")

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
