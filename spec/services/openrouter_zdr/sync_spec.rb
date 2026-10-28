# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Sync do
  let(:paid_endpoint) do
    {
      "model_id" => "openai/paid-zdr-model",
      "model_name" => "Paid ZDR Model",
      "context_length" => 200_000,
      "max_completion_tokens" => 16_000,
      "supported_parameters" => [ "tools" ],
      "pricing" => { "prompt" => "0.00001", "completion" => "0.00002" },
      "provider_name" => "Example Endpoint"
    }
  end
  let(:free_endpoint) do
    {
      "model_id" => "qwen/free-zdr-model:free",
      "model_name" => "Free ZDR Model",
      "context_length" => 128_000,
      "max_completion_tokens" => 8_000,
      "supported_parameters" => [ "tools" ],
      "pricing" => { "prompt" => "0", "completion" => "0" },
      "provider_name" => "Another Endpoint"
    }
  end

  before do
    allow(OpenrouterZdr::Client).to receive(:call).and_return([ paid_endpoint, free_endpoint ])
  end

  # @spec FREE-MODEL-SYNC-009, FREE-MODEL-SYNC-010
  it "maps paid and free endpoint records to concrete eligible model rows" do
    create(:llm_model,
      model_id: free_endpoint.fetch("model_id"), provider: "qwen", pricing_tier: "free",
      catalog_source: "openrouter_sync", metadata: { "below_quality_bar" => false })

    expect { described_class.call }.to change(LlmModel, :count).by(1)

    paid = LlmModel.find_by!(model_id: paid_endpoint.fetch("model_id"))
    free = LlmModel.find_by!(model_id: free_endpoint.fetch("model_id"))
    expect(paid).to have_attributes(
      display_name: "Paid ZDR Model", provider: "openai", pricing_tier: "paid", openrouter_zdr_eligible: true
    )
    expect(free).to have_attributes(pricing_tier: "free", openrouter_zdr_eligible: true)
    expect(paid.openrouter_zdr_endpoint_metadata).to include(paid_endpoint)
  end

  # @spec FREE-MODEL-SYNC-009
  it "is idempotent when the advertised endpoints have not changed" do
    described_class.call

    expect { described_class.call }.not_to change(LlmModel, :count)
  end

  # @spec FREE-MODEL-SYNC-011
  it "withdraws eligibility only after a successful refresh, including an empty catalog" do
    model = create(:llm_model, model_id: "openai/withdrawn", openrouter_zdr_eligible: true)
    allow(OpenrouterZdr::Client).to receive(:call).and_return([])

    result = described_class.call

    expect(result).to be_success
    expect(model.reload.openrouter_zdr_eligible).to be(false)
    expect(OpenrouterZdrCatalogRefresh.current.last_successful_at).to be_present
  end

  # @spec FREE-MODEL-SYNC-012
  it "preserves last-known eligibility and records unavailability for malformed endpoint data" do
    model = create(:llm_model, model_id: "openai/known", openrouter_zdr_eligible: true)
    refresh = OpenrouterZdrCatalogRefresh.current
    refresh.update!(last_successful_at: 1.hour.ago)
    allow(OpenrouterZdr::Client).to receive(:call).and_return([ { "model_name" => "Missing id" } ])

    result = described_class.call

    expect(result).to be_unavailable
    expect(model.reload.openrouter_zdr_eligible).to be(true)
    expect(refresh.reload.last_successful_at).to be_within(1.second).of(1.hour.ago)
    expect(refresh.last_error).to include("model_id")
  end

  # @spec FREE-MODEL-SYNC-012
  it "preserves last-known eligibility when the endpoint request fails" do
    model = create(:llm_model, model_id: "openai/known", openrouter_zdr_eligible: true)
    allow(OpenrouterZdr::Client).to receive(:call).and_raise(OpenrouterZdr::Client::Error, "timed out")

    result = described_class.call

    expect(result).to be_unavailable
    expect(model.reload.openrouter_zdr_eligible).to be(true)
    expect(OpenrouterZdrCatalogRefresh.current.last_attempted_at).to be_present
  end
end
