# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::Runner::SupersededModel do
  it "returns a finding when a stronger sibling exists in the same provider and tier" do
    model = create(:llm_model, :openai, model_id: "gpt-older", tier: "mid", capability_score: 7.0)
    create(:llm_model, :openai, model_id: "gpt-newer", tier: "mid", capability_score: 9.0)
    runner = create_runner_with_model(model, tier: "mid")

    expect(described_class.call(runner)).to contain_exactly(
      have_attributes(
        check: described_class.name,
        scope: :runner,
        severity: :info,
        message: "Runner #{runner.display_name} resolves superseded model gpt-older for mid tier; consider gpt-newer."
      )
    )
  end

  it "returns no findings when no stronger sibling exists" do
    model = create(:llm_model, :openai, model_id: "gpt-current", tier: "mid", capability_score: 9.0)
    create(:llm_model, :openai, model_id: "gpt-weaker", tier: "mid", capability_score: 7.0)
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
