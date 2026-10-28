# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Catalog do
  let!(:openai_model) do
    create(:llm_model, :openai, model_id: "openai/eligible", metadata: { "openrouter_zdr_eligible" => true })
  end
  let!(:anthropic_model) do
    create(:llm_model, model_id: "anthropic/eligible", provider: "anthropic", metadata: { "openrouter_zdr_eligible" => true })
  end

  # @spec FREE-MODEL-SYNC-012
  it "keeps the active eligibility query compatible with runner and project restrictions" do
    project = create(:project, model_preferences: { "llm_providers" => { "allowlist" => [ "openai" ] } })

    expect(described_class.eligible_models(runner_key: "codex", project:)).to eq([ openai_model ])
  end

  # @spec FREE-MODEL-SYNC-012
  it "returns only active endpoint-eligible rows without a selection context" do
    expect(described_class.eligible_models).to contain_exactly(openai_model, anthropic_model)
  end
end
