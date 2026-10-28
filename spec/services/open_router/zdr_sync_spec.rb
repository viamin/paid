# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenRouter::ZdrSync do
  let(:payloads) { fixture_payloads("openrouter/zdr_endpoints.json") }

  before do
    allow(OpenRouter::ZdrClient).to receive(:call).and_return(payloads)
  end

  # @spec FREE-MODEL-SYNC-009
  # @spec FREE-MODEL-SYNC-010
  # @spec FREE-MODEL-SYNC-011
  it "maps paid and free endpoint eligibility to catalog models idempotently" do
    expect { described_class.call }.to change(OpenRouterZdrCatalogEntry, :count).by(2)

    catalog = OpenRouterZdrCatalog.current
    paid = LlmModel.find_by!(model_id: "openai/gpt-paid")
    free = LlmModel.find_by!(model_id: "qwen/free-zdr")

    aggregate_failures do
      expect(catalog).to be_available
      expect(catalog.last_successful_at).to be_present
      expect(catalog.eligible_models).to contain_exactly(paid, free)
      expect(paid).to have_attributes(catalog_source: "openrouter_zdr_sync", pricing_tier: "paid", provider: "openai")
      expect(free).to have_attributes(catalog_source: "openrouter_zdr_sync", pricing_tier: "free", provider: "qwen")
      expect(catalog.entries.find_by!(llm_model: paid)).to have_attributes(endpoint_count: 2)
    end

    expect { described_class.call }.not_to change(OpenRouterZdrCatalogEntry, :count)
  end

  # @spec FREE-MODEL-SYNC-011
  it "withdraws eligibility without taking ownership from the free catalog" do
    free_sync_model = create(:llm_model, model_id: "qwen/free-zdr", provider: "qwen", pricing_tier: "free",
      catalog_source: "openrouter_sync", active: true)
    described_class.call

    allow(OpenRouter::ZdrClient).to receive(:call).and_return([ payloads.first ])

    described_class.call

    aggregate_failures do
      expect(OpenRouterZdrCatalog.current.eligible_models.map(&:model_id)).to eq([ "openai/gpt-paid" ])
      expect(free_sync_model.reload).to be_active
      expect(OpenRouterZdrCatalogEntry.find_by(llm_model: free_sync_model)).to be_nil
    end
  end

  # @spec FREE-MODEL-SYNC-012
  it "preserves the last successful catalog and marks it unavailable after a failed refresh" do
    described_class.call
    catalog = OpenRouterZdrCatalog.current
    successful_at = catalog.last_successful_at
    expected_ids = catalog.eligible_models.pluck(:model_id)
    allow(OpenRouter::ZdrClient).to receive(:call).and_raise(OpenRouter::ZdrClient::ParseError, "invalid response")

    expect { described_class.call }.to raise_error(OpenRouter::ZdrClient::ParseError)

    catalog.reload
    aggregate_failures do
      expect(catalog).not_to be_available
      expect(catalog.last_successful_at).to eq(successful_at)
      expect(catalog.last_error).to include("invalid response")
      expect(catalog.eligible_models.pluck(:model_id)).to match_array(expected_ids)
    end
  end

  # @spec FREE-MODEL-SYNC-011
  it "treats a successful empty response as a fresh empty catalog" do
    described_class.call
    allow(OpenRouter::ZdrClient).to receive(:call).and_return([])

    described_class.call

    catalog = OpenRouterZdrCatalog.current
    expect(catalog).to be_available
    expect(catalog.eligible_models).to be_empty
  end

  def fixture_payloads(path)
    JSON.parse(file_fixture(path).read).fetch("data")
  end
end
