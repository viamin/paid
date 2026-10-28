# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Sync do
  let(:endpoints) { JSON.parse(file_fixture("openrouter_zdr_endpoints.json").read).fetch("data") }

  before { allow(OpenrouterZdr::Client).to receive(:call).and_return(endpoints) }

  # @spec FREE-MODEL-SYNC-009
  it "maps paid and free endpoint model ids without deriving eligibility from price" do
    described_class.call

    expect(OpenrouterZdr::Catalog.eligible_models.map(&:model_id)).to contain_exactly(
      "acme/paid-code", "acme/free-code:free"
    )
    expect(LlmModel.find_by!(model_id: "acme/paid-code").pricing_tier).to eq("paid")
    expect(LlmModel.find_by!(model_id: "acme/free-code:free").pricing_tier).to eq("free")
  end

  # @spec FREE-MODEL-SYNC-009
  it "is idempotent while retaining every advertised endpoint for a model" do
    allow(OpenrouterZdr::Client).to receive(:call).and_return(endpoints + [ endpoints.first ])

    described_class.call

    expect { described_class.call }.not_to change(LlmModel, :count)
    expect(LlmModel.find_by!(model_id: "acme/paid-code").metadata.fetch("openrouter_zdr_endpoints").size).to eq(2)
  end

  # @spec FREE-MODEL-SYNC-010
  it "removes withdrawn eligibility without deactivating a free-sync row" do
    free_model = create(:llm_model, model_id: "acme/free-code:free", provider: "acme",
      pricing_tier: "free", catalog_source: "openrouter_sync", active: true)
    described_class.call
    allow(OpenrouterZdr::Client).to receive(:call).and_return([])

    described_class.call

    expect(OpenrouterZdr::Catalog.eligible_models).to be_empty
    expect(free_model.reload).to be_active
  end

  # @spec FREE-MODEL-SYNC-011
  it "preserves the last known catalog and marks it unavailable after a refresh failure" do
    described_class.call
    allow(OpenrouterZdr::Client).to receive(:call).and_raise(OpenrouterZdr::Client::Error, "timeout")

    expect { described_class.call }.to raise_error(OpenrouterZdr::Client::Error)

    expect(OpenrouterZdr::Catalog.eligible_models.map(&:model_id)).to include("acme/paid-code")
    expect(OpenrouterZdr::Catalog.freshness).to have_attributes(available?: false, successful?: true)
  end

  # @spec FREE-MODEL-SYNC-011
  it "preserves the last known catalog when a malformed endpoint response is rejected" do
    described_class.call
    allow(OpenrouterZdr::Client).to receive(:call).and_raise(OpenrouterZdr::Client::ParseError, "missing model_id")

    expect { described_class.call }.to raise_error(OpenrouterZdr::Client::ParseError)

    expect(OpenrouterZdr::Catalog.eligible_models.map(&:model_id)).to include("acme/paid-code")
    expect(OpenrouterZdr::Catalog.freshness).to have_attributes(available?: false, successful?: true)
  end

  # @spec FREE-MODEL-SYNC-011
  it "records a successful empty refresh distinctly from an unavailable catalog" do
    allow(OpenrouterZdr::Client).to receive(:call).and_return([])

    described_class.call

    expect(OpenrouterZdr::Catalog.eligible_models).to be_empty
    expect(OpenrouterZdr::Catalog.freshness).to have_attributes(available?: true, successful?: true)
  end
end
