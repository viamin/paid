# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Client do
  # @spec FREE-MODEL-SYNC-009
  it "returns endpoint payloads from OpenRouter's ZDR endpoint" do
    stub_request(:get, "https://openrouter.ai/api/v1/endpoints/zdr")
      .to_return(status: 200, body: file_fixture("openrouter_zdr_endpoints.json").read)

    expect(described_class.call.map { |endpoint| endpoint.fetch("model_id") }).to eq(
      %w[acme/paid-code acme/free-code:free]
    )
  end

  # @spec FREE-MODEL-SYNC-011
  it "rejects a successful response without an endpoint data array" do
    stub_request(:get, "https://openrouter.ai/api/v1/endpoints/zdr")
      .to_return(status: 200, body: "{}")

    expect { described_class.call }.to raise_error(OpenrouterZdr::Client::ParseError)
  end

  it "rejects endpoint entries that do not name a model" do
    stub_request(:get, "https://openrouter.ai/api/v1/endpoints/zdr")
      .to_return(status: 200, body: { data: [ { provider_name: "Unknown" } ] }.to_json)

    expect { described_class.call }.to raise_error(OpenrouterZdr::Client::ParseError)
  end
end
