# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Catalog do
  # @spec FREE-MODEL-SYNC-013
  it "returns eligible active OpenRouter candidates with explicit freshness" do
    eligible = create(:llm_model, model_id: "openai/gpt-zdr", provider: "openrouter",
      openrouter_zdr_eligible: true, catalog_source: "openrouter_zdr_sync")
    create(:llm_model, model_id: "openai/gpt-withdrawn", provider: "openrouter",
      openrouter_zdr_eligible: false, catalog_source: "openrouter_zdr_sync")
    refresh = OpenrouterZdrRefresh.current
    refresh.update!(status: "available", last_success_at: Time.current)

    result = described_class.call

    expect(result.models).to contain_exactly(eligible)
    expect(result.refresh).to have_attributes(status: "available")
  end

  # @spec FREE-MODEL-SYNC-013
  it "keeps existing project provider restrictions when querying candidates" do
    create(:llm_model, model_id: "openai/gpt-zdr", provider: "openrouter",
      openrouter_zdr_eligible: true, catalog_source: "openrouter_zdr_sync")
    project = create(:project, model_preferences: { "llm_providers" => { "allowlist" => [ "anthropic" ] } })

    expect(described_class.call(project: project).models).to be_empty
  end
end
