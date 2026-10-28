# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Catalog do
  let!(:eligible) do
    create(:llm_model, model_id: "openrouter/eligible", provider: "openrouter", capability_score: 9.0)
  end

  before do
    create(:llm_model, model_id: "openrouter/ineligible", provider: "openrouter", capability_score: 10.0)
    OpenrouterZdrSync.create!(id: 1, status: "available", last_successful_at: Time.current)
    OpenrouterZdrEndpoint.create!(model_id: eligible.model_id, endpoint_name: "Provider | eligible", last_seen_at: Time.current)
  end

  it "returns only models with at least one advertised endpoint" do # @spec OPENROUTER-ZDR-007
    result = described_class.call

    expect(result.models).to eq([ eligible ])
    expect(result).to be_available
  end

  it "retains freshness status when the catalog is unavailable" do # @spec OPENROUTER-ZDR-005
    OpenrouterZdrSync.current.update!(status: "unavailable", error_message: "timeout")

    result = described_class.call

    expect(result.models).to eq([ eligible ])
    expect(result).not_to be_available
    expect(result.freshness.error_message).to eq("timeout")
  end
end
