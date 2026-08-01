# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::Runner::ExpiredModel do
  it "returns a finding when a tier resolves to an expired model" do
    model = create(:llm_model, :openai, model_id: "gpt-expired", tier: "mid", expires_at: 1.day.ago)
    runner = create_runner_with_model(model, tier: "mid")

    expect(described_class.call(runner)).to contain_exactly(
      have_attributes(
        check: described_class.name,
        scope: :runner,
        severity: :warning,
        message: "Runner #{runner.display_name} resolves expired model gpt-expired for mid tier."
      )
    )
  end

  it "returns no findings when resolved models are not expired" do
    model = create(:llm_model, :openai, model_id: "gpt-current", tier: "mid", expires_at: 1.day.from_now)
    runner = create_runner_with_model(model, tier: "mid")

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
