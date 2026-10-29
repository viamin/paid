# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Client do
  # @spec FREE-MODEL-SYNC-009
  it "rejects malformed endpoint records" do
    stub_request(:get, "https://openrouter.ai/api/v1/endpoints/zdr")
      .to_return(status: 200, body: { data: [ { name: "missing model id" } ] }.to_json)

    expect { described_class.call }.to raise_error(OpenrouterZdr::Client::ParseError, /model_id/)
  end

  # @spec FREE-MODEL-SYNC-012
  it "normalizes TLS failures as client errors" do
    stub_request(:get, "https://openrouter.ai/api/v1/endpoints/zdr")
      .to_raise(Faraday::SSLError.new("certificate verify failed"))

    expect { described_class.call }
      .to raise_error(OpenrouterZdr::Client::Error, /certificate verify failed/)
  end
end
