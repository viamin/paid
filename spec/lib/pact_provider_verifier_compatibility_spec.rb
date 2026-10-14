# frozen_string_literal: true

require "rails_helper"
require_relative "../../lib/pact_provider_verifier_compatibility"

RSpec.describe PactProviderVerifierCompatibility, :no_db do
  # @spec MOBILE-API-017
  it "restores its Rack 2 and JSON 2 interfaces for the isolated verifier process" do
    expect(Rack::Utils::HeaderHash).to be < Rack::Headers
    expect(Rack::Utils::HeaderHash.new("Content-Type" => [ "application/json" ]))
      .to include("content-type" => "application/json")
    expect(JSON.load(%({"count":1}), nil, { max_nesting: 50 })).to eq("count" => 1)
  end
end
