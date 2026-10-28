# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Sync do
  let(:endpoints) do
    [
      { "model_id" => "openai/paid-zdr", "model_name" => "Paid ZDR", "context_length" => 128_000,
        "max_completion_tokens" => 16_000, "supported_parameters" => [ "tools" ], "pricing" => { "prompt" => "0.1", "completion" => "0.2" } },
      { "model_id" => "openai/paid-zdr", "model_name" => "Paid ZDR", "pricing" => { "prompt" => "0.1", "completion" => "0.2" } },
      { "model_id" => "qwen/free-zdr", "model_name" => "Free ZDR", "pricing" => { "prompt" => "0", "completion" => "0" } }
    ]
  end

  before { allow(OpenrouterZdr::Client).to receive(:call).and_return(endpoints) }

  it "maps paid and free endpoint records to eligible model ids" do # @spec OPENROUTER-ZDR-CATALOG-001, OPENROUTER-ZDR-CATALOG-002
    described_class.call

    expect(OpenrouterZdrEligibility.active.pluck(:model_id)).to contain_exactly("openai/paid-zdr", "qwen/free-zdr")
    expect(OpenrouterZdrEligibility.find_by!(model_id: "openai/paid-zdr")).to have_attributes(endpoint_count: 2)
    expect(LlmModel.find_by!(model_id: "openai/paid-zdr")).to have_attributes(pricing_tier: "paid", supports_tools: true)
    expect(LlmModel.find_by!(model_id: "qwen/free-zdr").pricing_tier).to eq("free")
  end

  it "withdraws eligibility only after a successful refresh" do # @spec OPENROUTER-ZDR-CATALOG-003
    described_class.call
    allow(OpenrouterZdr::Client).to receive(:call).and_return([])

    described_class.call

    expect(OpenrouterZdrEligibility.find_by!(model_id: "openai/paid-zdr")).not_to be_active
    expect(OpenrouterZdrCatalogStatus.current).to be_fresh
  end

  it "is idempotent and does not take ownership of a free-sync row" do # @spec OPENROUTER-ZDR-CATALOG-002, OPENROUTER-ZDR-CATALOG-003
    free_row = create(:llm_model, model_id: "qwen/free-zdr", catalog_source: "openrouter_sync", pricing_tier: "free")

    described_class.call

    expect { described_class.call }.not_to change(OpenrouterZdrEligibility, :count)
    expect(free_row.reload).to be_active
  end

  it "preserves the prior catalog and marks it unavailable on malformed responses" do # @spec OPENROUTER-ZDR-CATALOG-004
    described_class.call
    allow(OpenrouterZdr::Client).to receive(:call).and_return([ { "name" => "missing model" } ])

    result = described_class.call

    expect(result.available).to be(false)
    expect(OpenrouterZdrEligibility.find_by!(model_id: "openai/paid-zdr")).to be_active
    expect(OpenrouterZdrCatalogStatus.current).not_to be_fresh
  end

  it "preserves the prior catalog and marks it unavailable on refresh failure" do # @spec OPENROUTER-ZDR-CATALOG-004
    described_class.call
    allow(OpenrouterZdr::Client).to receive(:call).and_raise(OpenrouterZdr::Client::ResponseError, "503")

    described_class.call

    expect(OpenrouterZdrEligibility.find_by!(model_id: "openai/paid-zdr")).to be_active
    expect(OpenrouterZdrCatalogStatus.current).to have_attributes(status: "unavailable", last_successful_at: be_present)
  end

  it "exposes eligible rows with their unavailable freshness status" do # @spec OPENROUTER-ZDR-CATALOG-004, OPENROUTER-ZDR-CATALOG-005
    described_class.call
    allow(OpenrouterZdr::Client).to receive(:call).and_raise(OpenrouterZdr::Client::ResponseError, "503")
    described_class.call

    snapshot = OpenrouterZdr::Catalog.call

    expect(snapshot).not_to be_fresh
    expect(snapshot.models.pluck(:model_id)).to include("openai/paid-zdr")
  end
end
