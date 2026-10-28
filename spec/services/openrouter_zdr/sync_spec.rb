# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Sync do
  let(:snapshot) do
    OpenrouterZdr::Client::Snapshot.new(
      endpoints: JSON.parse(file_fixture("openrouter_zdr/endpoints.json").read).fetch("data"),
      models: JSON.parse(file_fixture("openrouter_zdr/models.json").read).fetch("data")
    )
  end

  before { allow(OpenrouterZdr::Client).to receive(:call).and_return(snapshot) }

  it "maps paid and free model ids from advertised endpoints without inferring from pricing" do # @spec FREE-MODEL-SYNC-009 @spec FREE-MODEL-SYNC-010
    described_class.call

    paid = OpenrouterZdrModel.find_by!(model_id: "paid/model")
    free = OpenrouterZdrModel.find_by!(model_id: "free/model:free")

    expect(paid.metadata.fetch("endpoints").size).to eq(2)
    expect(paid.metadata.dig("model", "name")).to eq("Paid Model")
    expect(free).to be_active
    expect(LlmModel.find_by!(model_id: "paid/model").pricing_tier).to eq("paid")
    expect(LlmModel.find_by!(model_id: "free/model:free").pricing_tier).to eq("free")
  end

  it "is idempotent and removes eligibility only after a successful refresh" do # @spec FREE-MODEL-SYNC-011
    described_class.call
    expect { described_class.call }.not_to change(OpenrouterZdrModel, :count)

    allow(OpenrouterZdr::Client).to receive(:call).and_return(
      OpenrouterZdr::Client::Snapshot.new(endpoints: [], models: snapshot.models)
    )
    described_class.call

    expect(OpenrouterZdrModel.active).to be_empty
    expect(OpenrouterZdrCatalogState.instance).to be_available
  end

  it "preserves last-known eligibility and records unavailability on refresh failure" do # @spec FREE-MODEL-SYNC-012
    described_class.call
    allow(OpenrouterZdr::Client).to receive(:call).and_raise(OpenrouterZdr::Client::ParseError, "invalid response")

    expect { described_class.call }.to raise_error(OpenrouterZdr::Client::ParseError)

    expect(OpenrouterZdrModel.active.pluck(:model_id)).to contain_exactly("free/model:free", "paid/model")
    expect(OpenrouterZdrCatalogState.instance).to be_unavailable
  end

  it "preserves the free catalog row ownership when the same model has a ZDR endpoint" do # @spec FREE-MODEL-SYNC-010
    free = create(:llm_model, model_id: "free/model:free", provider: "free", pricing_tier: "free", catalog_source: "openrouter_sync")

    described_class.call

    expect(free.reload.catalog_source).to eq("openrouter_sync")
  end

  it "does not withdraw prior eligibility when an endpoint cannot be mapped to model metadata" do # @spec FREE-MODEL-SYNC-012
    described_class.call
    bad_snapshot = OpenrouterZdr::Client::Snapshot.new(endpoints: [ { "model_id" => "missing/model" } ], models: snapshot.models)
    allow(OpenrouterZdr::Client).to receive(:call).and_return(bad_snapshot)

    expect { described_class.call }.to raise_error(OpenrouterZdr::Sync::MappingError)

    expect(OpenrouterZdrModel.active.pluck(:model_id)).to include("paid/model")
    expect(OpenrouterZdrCatalogState.instance).to be_unavailable
  end
end
