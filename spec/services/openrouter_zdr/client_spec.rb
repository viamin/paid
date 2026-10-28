# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::Client do
  # @spec FREE-MODEL-SYNC-009
  it "rejects malformed endpoint records" do
    stub_request(:get, "https://openrouter.ai/api/v1/endpoints/zdr")
      .to_return(status: 200, body: { data: [ { name: "missing model id" } ] }.to_json)

    expect { described_class.call }.to raise_error(OpenrouterZdr::Client::ParseError, /model_id/)
  end
end
