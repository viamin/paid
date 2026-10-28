# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Sync do
  let(:paid_endpoint) do
    {
      "name" => "Provider A | vendor/paid-model",
      "model_id" => "vendor/paid-model",
      "model_name" => "Vendor Paid Model",
      "context_length" => 128_000,
      "max_completion_tokens" => 16_000,
      "supported_parameters" => [ "tools" ],
      "pricing" => { "prompt" => "0.001", "completion" => "0.002" }
    }
  end

  let(:free_endpoint) do
    paid_endpoint.merge(
      "name" => "Provider B | vendor/free-model",
      "model_id" => "vendor/free-model",
      "model_name" => "Vendor Free Model",
      "pricing" => { "prompt" => "0", "completion" => "0" }
    )
  end

  # @spec FREE-MODEL-SYNC-009
  # @spec FREE-MODEL-SYNC-010
  # @spec FREE-MODEL-SYNC-011
  # @spec FREE-MODEL-SYNC-012
  it "maps paid and free endpoint eligibility without changing an existing free row" do
    free_row = create(:llm_model, model_id: "vendor/free-model", provider: "vendor",
      pricing_tier: "free", catalog_source: "openrouter_sync", metadata: { "free_catalog" => true })
    allow(OpenrouterZdr::Client).to receive(:call).and_return([ paid_endpoint, free_endpoint ])

    expect { described_class.call }.to change(OpenrouterZdrModel, :count).by(2)
      .and change(LlmModel, :count).by(1)

    expect(OpenrouterZdrModel.find_by!(model_id: "vendor/paid-model").endpoint_payloads).to eq([ paid_endpoint ])
    expect(LlmModel.find_by!(model_id: "vendor/paid-model")).to have_attributes(
      display_name: "Vendor Paid Model", pricing_tier: "paid", catalog_source: "openrouter_zdr_sync"
    )
    expect(free_row.reload).to have_attributes(catalog_source: "openrouter_sync", metadata: { "free_catalog" => true })
    expect(OpenrouterZdrCatalog.current).to have_attributes(unavailable_at: nil, last_successful_at: be_present)
  end

  # @spec FREE-MODEL-SYNC-011
  it "removes withdrawn eligibility only after a successful refresh" do
    withdrawn = create(:openrouter_zdr_model, model_id: "vendor/withdrawn")
    model = create(:llm_model, model_id: withdrawn.model_id, provider: "vendor")
    allow(OpenrouterZdr::Client).to receive(:call).and_return([ paid_endpoint ])

    described_class.call

    expect(OpenrouterZdrModel.find_by(model_id: withdrawn.model_id)).to be_nil
    expect(model.reload).to be_active
  end

  # @spec FREE-MODEL-SYNC-012
  it "preserves last-known eligibility and records unavailability after a refresh failure" do
    known = create(:openrouter_zdr_model, model_id: "vendor/known")
    catalog = OpenrouterZdrCatalog.current
    catalog.update!(last_successful_at: 1.hour.ago)
    allow(OpenrouterZdr::Client).to receive(:call).and_raise(OpenrouterZdr::Client::ResponseError, "502")

    expect { described_class.call }.not_to raise_error

    expect(OpenrouterZdrModel.find_by(id: known.id)).to be_present
    expect(catalog.reload).to have_attributes(last_successful_at: be_present, unavailable_at: be_present)
  end

  # @spec FREE-MODEL-SYNC-012
  it "treats a valid empty response as a successful empty catalog" do
    create(:openrouter_zdr_model, model_id: "vendor/known")
    allow(OpenrouterZdr::Client).to receive(:call).and_return([])

    described_class.call

    expect(OpenrouterZdrModel).to be_none
    expect(OpenrouterZdrCatalog.current).to have_attributes(last_successful_at: be_present, unavailable_at: nil)
  end
end
