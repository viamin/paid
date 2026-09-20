# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-NETWORK-001
RSpec.describe AgentRuns::AppleVerification::GuestContract do
  describe ".from_snapshot" do
    it "preserves a destination scheme restriction" do
      snapshot = AgentRuns::EgressPolicy::Snapshot.new(
        mode: "proxy_only",
        egress_profile: "locked",
        destinations: [ { "host" => "api.example.com", "port" => 8443, "scheme" => "https" } ],
        required_destinations: [ { "host" => "paid-proxy", "port" => 3000, "reason" => "secrets_proxy" } ]
      )

      contract = described_class.from_snapshot(snapshot)

      expect(contract.destinations).to eq([ { host: "api.example.com", port: 8443, scheme: "https" } ])
    end
  end
end
