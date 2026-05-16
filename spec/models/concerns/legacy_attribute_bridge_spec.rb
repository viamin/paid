# frozen_string_literal: true

require "rails_helper"

module LegacyAttributeBridgeSpec
  class Dummy
    include LegacyAttributeBridge

    def update_columns(*)
    end
  end
end

RSpec.describe LegacyAttributeBridge, :no_db do
  let(:bridge_host_class) { LegacyAttributeBridgeSpec::Dummy }

  describe ".synchronize_bridge_attributes" do
    let(:bridges) { { "provider_key" => "runner_key", "provider_id" => "runner_id" } }

    it "copies runner-named values into legacy keys" do
      synced = bridge_host_class.synchronize_bridge_attributes(
        { runner_key: "claude", runner_id: 12 },
        bridges
      )

      expect(synced).to include(
        "runner_key" => "claude",
        "provider_key" => "claude",
        "runner_id" => 12,
        "provider_id" => 12
      )
    end

    it "copies legacy values into runner-named keys" do
      synced = bridge_host_class.synchronize_bridge_attributes(
        { provider_key: "cursor", provider_id: 34 },
        bridges
      )

      expect(synced).to include(
        "runner_key" => "cursor",
        "provider_key" => "cursor",
        "runner_id" => 34,
        "provider_id" => 34
      )
    end
  end

  describe "#update_column" do
    it "delegates through update_columns so bridge-aware models keep aliases synchronized" do
      record = bridge_host_class.new

      expect(record).to receive(:update_columns).with("runner_key" => "codex")
      record.update_column("runner_key", "codex")
    end
  end
end
