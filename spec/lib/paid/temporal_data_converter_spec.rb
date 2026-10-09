# frozen_string_literal: true

require "rails_helper"
require "temporalio/api"

RSpec.describe Paid::TemporalDataConverter do
  # @spec TEMPORAL-ORCHESTRATION-011
  it "round-trips json/plain payloads with JSON 3" do
    payload = described_class.new.to_payload({ "project_id" => 1 })

    expect(payload.metadata["encoding"]).to eq("json/plain")
    expect(described_class.new.from_payload(payload)).to eq("project_id" => 1)
  end
end
