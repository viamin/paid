# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Sync do
  let(:payload) { JSON.parse(file_fixture("openrouter/zdr_endpoints.json").read).fetch("data") }

  before { allow(OpenrouterZdr::Client).to receive(:call).and_return(payload) }

  it "syncs paid and free endpoint-eligible model ids without inferring eligibility from price" do # @spec FREE-MODEL-SYNC-009 @spec FREE-MODEL-SYNC-010
    described_class.call

    paid = LlmModel.find_by!(model_id: "openai/gpt-paid")
    free = LlmModel.find_by!(model_id: "qwen/free-model")
    expect([ paid, free ]).to all(have_attributes(openrouter_zdr_eligible: true))
    expect(paid).to have_attributes(pricing_tier: "paid", catalog_source: "openrouter_zdr_sync")
    expect(free).to have_attributes(pricing_tier: "free", catalog_source: "openrouter_zdr_sync")
    expect(paid.metadata.dig("openrouter_zdr", "endpoints")).to include(a_hash_including("name" => "Azure | openai/gpt-paid"))
  end

  it "preserves a free catalog row's ownership while adding its ZDR eligibility" do # @spec FREE-MODEL-SYNC-010
    free = create(:llm_model, model_id: "qwen/free-model", catalog_source: "openrouter_sync", pricing_tier: "free")

    described_class.call

    expect(free.reload).to have_attributes(catalog_source: "openrouter_sync", openrouter_zdr_eligible: true)
  end

  it "withdraws missing eligibility after a successful refresh and deactivates only ZDR-owned rows" do # @spec FREE-MODEL-SYNC-011
    described_class.call
    free = create(:llm_model, model_id: "qwen/free-model:free", catalog_source: "openrouter_sync", pricing_tier: "free",
      openrouter_zdr_eligible: true)

    allow(OpenrouterZdr::Client).to receive(:call).and_return([])
    described_class.call

    expect(LlmModel.find_by!(model_id: "openai/gpt-paid")).to have_attributes(openrouter_zdr_eligible: false, active: false)
    expect(free.reload).to have_attributes(openrouter_zdr_eligible: false, active: true)
    expect(OpenrouterZdrCatalogState.current).to have_attributes(last_successful_at: be_present, unavailable_at: nil)
  end

  it "preserves last-known candidates and records unavailable when the refresh fails" do # @spec FREE-MODEL-SYNC-012
    described_class.call
    successful_at = OpenrouterZdrCatalogState.current.last_successful_at
    allow(OpenrouterZdr::Client).to receive(:call).and_raise(OpenrouterZdr::Client::ParseError, "invalid response")

    result = described_class.call

    expect(result).to be_unavailable
    expect(LlmModel.find_by!(model_id: "openai/gpt-paid")).to be_openrouter_zdr_eligible
    expect(OpenrouterZdrCatalogState.current).to have_attributes(last_successful_at: successful_at, unavailable_at: be_present,
      last_error: include("invalid response"))
  end

  it "treats malformed endpoint fixtures as unavailable without withdrawing candidates" do # @spec FREE-MODEL-SYNC-012
    described_class.call
    malformed = JSON.parse(file_fixture("openrouter/malformed_zdr_endpoints.json").read).fetch("data")
    allow(OpenrouterZdr::Client).to receive(:call).and_return(malformed)

    expect(described_class.call).to be_unavailable
    expect(LlmModel.find_by!(model_id: "openai/gpt-paid")).to be_openrouter_zdr_eligible
  end
end
