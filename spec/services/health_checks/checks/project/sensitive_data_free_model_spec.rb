# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::Project::SensitiveDataFreeModel do
  it "returns a warning for sensitive projects pinned to a risky free model" do
    model = create(:llm_model, :free, model_id: "free-model", catalog_source: "manual")
    project = build(
      :project,
      data_classification: "confidential",
      model_preferences: { "required_model_id" => model.model_id }
    )

    expect(described_class.call(project)).to contain_exactly(
      have_attributes(
        check: described_class.name,
        scope: :project,
        severity: :warning,
        message: "Sensitive project resolves to free model free-model with possible training risk."
      )
    )
  end

  it "returns no findings for sensitive projects pinned to an OpenRouter-routed free model" do
    model = create(:llm_model, :free, model_id: "openrouter-free-model", catalog_source: "openrouter_sync")
    project = build(
      :project,
      data_classification: "restricted",
      model_preferences: { "required_model_id" => model.model_id }
    )

    expect(described_class.call(project)).to eq([])
  end

  it "returns no findings for sensitive projects pinned to a risky free model via openrouter_free" do
    model = create(:llm_model, :free, model_id: "free-model", catalog_source: "manual")
    project = build(
      :project,
      data_classification: "confidential",
      model_preferences: {
        "required_model_id" => model.model_id,
        "preferred_agent_type" => "openrouter_free"
      }
    )

    expect(described_class.call(project)).to eq([])
  end
end
