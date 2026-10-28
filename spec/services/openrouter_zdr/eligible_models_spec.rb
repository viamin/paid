# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::EligibleModels do
  it "returns active endpoint-eligible rows with explicit unavailable freshness" do # @spec FREE-MODEL-SYNC-013
    eligible = create(:llm_model, model_id: "openai/gpt-paid", provider: "openai", openrouter_zdr_eligible: true)
    create(:llm_model, :inactive, model_id: "openai/withdrawn", provider: "openai", openrouter_zdr_eligible: true)
    OpenrouterZdrCatalogState.current.update!(last_successful_at: 1.hour.ago, unavailable_at: Time.current, last_error: "timeout")

    result = described_class.call

    expect(result.models).to eq([ eligible ])
    expect(result).to be_unavailable
    expect(result.last_successful_at).to be_present
    expect(result.freshness).to eq(:unavailable)
  end

  it "reports an unverified catalog before any successful refresh" do # @spec FREE-MODEL-SYNC-013
    expect(described_class.call.freshness).to eq(:unverified)
  end
end
