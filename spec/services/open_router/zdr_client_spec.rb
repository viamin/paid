# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenRouter::ZdrClient do
  # @spec FREE-MODEL-SYNC-012
  it "rejects a response whose data is not an endpoint array" do
    connection = instance_double(Faraday::Connection)
    response = instance_double(Faraday::Response, success?: true, body: file_fixture("openrouter/zdr_malformed.json").read)
    allow(Faraday).to receive(:new).and_return(connection)
    allow(connection).to receive(:get).and_return(response)

    expect { described_class.call }.to raise_error(described_class::ParseError, /data array/)
  end
end
