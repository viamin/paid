# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Client do
  it "returns endpoint records from the ZDR fixture" do # @spec OPENROUTER-ZDR-CATALOG-001
    stub_request(:get, described_class::API_URL).to_return(status: 200,
      body: file_fixture("openrouter_zdr_endpoints.json").read, headers: { "Content-Type" => "application/json" })

    expect(described_class.call).to include(hash_including("model_id" => "openai/paid-zdr"))
  end

  it "rejects malformed responses" do # @spec OPENROUTER-ZDR-CATALOG-004
    stub_request(:get, described_class::API_URL).to_return(status: 200, body: "{not-json")

    expect { described_class.call }.to raise_error(OpenrouterZdr::Client::ParseError)
  end
end
