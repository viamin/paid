# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::Runner::IncompatibleModel do
  it "returns a finding when a tier resolves to a model incompatible with the runner contract" do
    model = create(:llm_model, model_id: "claude-test", provider: "anthropic", tier: "high")
    runner = create_runner_with_model(model, tier: "high")

    expect(described_class.call(runner)).to contain_exactly(
      have_attributes(
        check: described_class.name,
        scope: :runner,
        severity: :error,
        message: "Runner #{runner.display_name} resolves incompatible model for high tier: model 'claude-test' is not compatible with runner 'codex' at tier 'high': 'claude-test' belongs to provider 'anthropic', not 'openai' (required for codex)."
      )
    )
  end

  it "treats nil compatibility results as permissive" do
    model = create(:llm_model, :openai, model_id: "gpt-unknown", tier: "high")
    runner = create_runner_with_model(model, tier: "high")

    allow(Runners::ResolveTierModel).to receive(:call) do |**args|
      if args[:runner] == runner && args[:user] == runner.user && args[:tier] == "high"
        Runners::ResolveTierModel::Result.new(model_id: model.model_id, source: "runner")
      else
        Runners::ResolveTierModel::Result.new(
          error: "no model configured for #{args[:runner].runner_key} at #{args[:tier]}"
        )
      end
    end
    allow(Runners::ModelCompatibility).to receive(:call) do |**args|
      next nil if args[:model_id] == model.model_id

      Runners::ModelCompatibility::Result.new(supported: nil, source: "test")
    end

    expect(described_class.call(runner)).to eq([])
  end

  it "returns no findings when the resolved model is compatible" do
    model = create(:llm_model, :openai, model_id: "gpt-compatible", tier: "high")
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
      provider_api_key: api_key
    ).tap do |runner|
      runner.update_columns(tier_model_ids: { tier => model.model_id })
    end
  end
end
