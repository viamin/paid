# frozen_string_literal: true

require "rails_helper"

# @spec FREE-MODEL-SYNC-001
RSpec.describe FreeModels::Client do
  describe ".call" do
    it "returns the parsed data array from OpenRouter" do
      stub_request(:get, "https://openrouter.ai/api/v1/models")
        .to_return(status: 200, body: { data: [ { id: "deepseek/model:free" } ] }.to_json,
          headers: { "Content-Type" => "application/json" })

      expect(described_class.call).to eq([ { "id" => "deepseek/model:free" } ])
    end

    it "raises a response error for non-success statuses" do
      stub_request(:get, "https://openrouter.ai/api/v1/models")
        .to_return(status: 502, body: "bad gateway")

      expect { described_class.call }.to raise_error(FreeModels::Client::ResponseError, /502/)
    end

    it "raises a parse error for invalid JSON" do
      stub_request(:get, "https://openrouter.ai/api/v1/models")
        .to_return(status: 200, body: "{not-json", headers: { "Content-Type" => "application/json" })

      expect { described_class.call }.to raise_error(FreeModels::Client::ParseError)
    end
  end
end
