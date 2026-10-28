# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Client do
  let(:url) { described_class::API_URL }

  it "returns endpoint-level entries" do # @spec OPENROUTER-ZDR-001
    stub_request(:get, url).to_return(body: { data: [ { "name" => "Vendor | model", "model_id" => "vendor/model" } ] }.to_json)

    expect(described_class.call).to eq([ { "name" => "Vendor | model", "model_id" => "vendor/model" } ])
  end

  it "rejects malformed endpoint entries" do # @spec OPENROUTER-ZDR-006
    stub_request(:get, url).to_return(body: { data: [ { "name" => "missing model id" } ] }.to_json)

    expect { described_class.call }.to raise_error(OpenrouterZdr::Client::ParseError)
  end

  it "allows a successful empty catalog" do # @spec OPENROUTER-ZDR-004
    stub_request(:get, url).to_return(body: { data: [] }.to_json)

    expect(described_class.call).to eq([])
  end
end
