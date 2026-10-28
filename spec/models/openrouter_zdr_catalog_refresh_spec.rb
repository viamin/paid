# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdrCatalogRefresh, type: :model do
  # @spec FREE-MODEL-SYNC-012
  it "uses one persistent freshness record for the endpoint catalog" do
    expect { described_class.current }.to change(described_class, :count).by(1)
    expect(described_class.current.catalog_key).to eq("openrouter_zdr")
  end
end
