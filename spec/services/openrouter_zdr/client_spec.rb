# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Client do
  it "returns endpoint and model arrays" do # @spec FREE-MODEL-SYNC-009
    stub_request(:get, described_class::ZDR_API_URL).to_return(status: 200, body: file_fixture("openrouter_zdr/endpoints.json").read)
    stub_request(:get, described_class::MODELS_API_URL).to_return(status: 200, body: file_fixture("openrouter_zdr/models.json").read)

    expect(described_class.call.endpoints.map { |endpoint| endpoint.fetch("model_id") }).to include("paid/model")
  end

  it "rejects malformed endpoint responses" do # @spec FREE-MODEL-SYNC-012
    stub_request(:get, described_class::ZDR_API_URL).to_return(status: 200, body: "{not-json")

    expect { described_class.call }.to raise_error(described_class::ParseError)
  end
end
