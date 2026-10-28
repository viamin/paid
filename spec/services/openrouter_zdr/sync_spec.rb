# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Sync do
  let(:endpoint_payloads) do
    JSON.parse(file_fixture("openrouter_zdr/eligible_endpoints.json").read).fetch("data")
  end

  before do
    allow(OpenrouterZdr::Client).to receive(:call).and_return(endpoint_payloads)
  end

  # @spec FREE-MODEL-SYNC-009
  # @spec FREE-MODEL-SYNC-010
  it "maps eligible endpoint evidence to paid and free OpenRouter models" do
    described_class.call

    paid = LlmModel.find_by!(model_id: "openai/paid-model")
    free = LlmModel.find_by!(model_id: "qwen/free-model:free")

    aggregate_failures do
      expect(paid).to have_attributes(
        catalog_source: "openrouter_zdr_sync",
        pricing_tier: "paid",
        zdr_eligible: true,
        context_window: 200_000,
        max_output_tokens: 32_000
      )
      expect(paid.metadata.fetch("openrouter_zdr_endpoints").size).to eq(2)
      expect(free).to have_attributes(pricing_tier: "free", zdr_eligible: true)
    end
  end

  # @spec FREE-MODEL-SYNC-011
  it "preserves free-catalog ownership while attaching ZDR evidence" do
    free = create(:llm_model, model_id: "qwen/free-model:free", catalog_source: "openrouter_sync",
      pricing_tier: "free", metadata: { "below_quality_bar" => true })

    described_class.call

    expect(free.reload).to have_attributes(catalog_source: "openrouter_sync", zdr_eligible: true)
    expect(free.metadata).to include("below_quality_bar" => true, "openrouter_zdr_endpoint_count" => 1)
  end

  # @spec FREE-MODEL-SYNC-012
  it "withdraws eligibility only after a successful refresh, including a successful empty catalog" do
    described_class.call
    allow(OpenrouterZdr::Client).to receive(:call).and_return([])

    described_class.call

    expect(LlmModel.where(zdr_eligible: true)).to be_empty
    expect(OpenrouterZdrCatalogStatus.current).to have_attributes(status: "available", last_success_at: be_present)
  end

  # @spec FREE-MODEL-SYNC-013
  it "preserves last-known eligibility and records unavailability on malformed responses" do
    described_class.call
    last_success = OpenrouterZdrCatalogStatus.current.last_success_at
    allow(OpenrouterZdr::Client).to receive(:call).and_return([ { "model_name" => "Malformed endpoint" } ])

    expect { described_class.call }.to raise_error(OpenrouterZdr::Client::ParseError, "OpenRouter ZDR endpoint was missing model_id")

    expect(LlmModel.where(zdr_eligible: true).count).to eq(2)
    expect(OpenrouterZdrCatalogStatus.current).to have_attributes(
      status: "unavailable",
      last_success_at: last_success,
      last_error: "OpenRouter ZDR endpoint was missing model_id"
    )
  end

  # @spec FREE-MODEL-SYNC-014
  it "is idempotent and exposes active eligible models with freshness" do
    described_class.call

    expect { described_class.call }.not_to change(LlmModel, :count)
    catalog = OpenrouterZdr::Catalog.call

    expect(catalog.models.map(&:model_id)).to contain_exactly("openai/paid-model", "qwen/free-model:free")
    expect(catalog.status).to be_available
  end

  it "honors project OpenRouter provider restrictions" do # @spec FREE-MODEL-SYNC-014
    described_class.call
    project = build(:project, model_preferences: { "llm_providers" => { "allowlist" => [ "anthropic" ] } })

    expect(OpenrouterZdr::Catalog.call(project:).models).to be_empty
  end
end
