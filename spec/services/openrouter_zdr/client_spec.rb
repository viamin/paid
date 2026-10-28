# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Client do
  # @spec FREE-MODEL-SYNC-009
  it "returns the endpoint data array from OpenRouter" do
    body = file_fixture("openrouter_zdr/eligible_endpoints.json").read
    stub_request(:get, described_class::API_URL).to_return(status: 200, body: body)

    expect(described_class.call).to include(hash_including("model_id" => "openai/gpt-paid"))
  end

  # @spec FREE-MODEL-SYNC-012
  it "rejects malformed endpoint payloads" do
    body = file_fixture("openrouter_zdr/malformed_endpoints.json").read
    stub_request(:get, described_class::API_URL).to_return(status: 200, body: body)

    expect { OpenrouterZdr::Sync.call }.to raise_error(OpenrouterZdr::Client::ParseError, /invalid endpoint/)
  end
end
