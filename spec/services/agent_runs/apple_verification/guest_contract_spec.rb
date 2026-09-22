# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-NETWORK-001
# @spec APPLE-NETWORK-002
RSpec.describe AgentRuns::AppleVerification::GuestContract do
  describe ".from_snapshot" do
    it "preserves a destination scheme restriction" do
      snapshot = AgentRuns::EgressPolicy::Snapshot.new(
        mode: "proxy_only",
        egress_profile: "locked",
        destinations: [ { "host" => "api.example.com", "port" => 8443, "scheme" => "https" } ],
        required_destinations: [
          { "host" => "egress-gateway", "port" => 3128, "reason" => "egress_gateway" },
          { "host" => "paid-proxy", "port" => 3000, "reason" => "secrets_proxy" }
        ]
      )

      contract = described_class.from_snapshot(snapshot)

      expect(contract.destinations).to eq([ { host: "api.example.com", port: 8443, scheme: "https" } ])
    end

    it "builds the proxy endpoint from the egress-gateway, not the secrets-proxy" do
      snapshot = AgentRuns::EgressPolicy::Snapshot.new(
        mode: "proxy_only",
        egress_profile: "locked",
        destinations: [],
        required_destinations: [
          { "host" => "egress-gateway", "port" => 3128, "reason" => "egress_gateway" },
          { "host" => "paid-proxy", "port" => 3000, "reason" => "secrets_proxy" }
        ]
      )

      contract = described_class.from_snapshot(snapshot)

      expect(contract.proxy).to eq(host: "egress-gateway", port: 3128)
    end

    it "raises when the snapshot has no egress-gateway required destination" do
      snapshot = AgentRuns::EgressPolicy::Snapshot.new(
        mode: "proxy_only",
        egress_profile: "locked",
        destinations: [],
        required_destinations: [ { "host" => "paid-proxy", "port" => 3000, "reason" => "secrets_proxy" } ]
      )

      expect { described_class.from_snapshot(snapshot) }
        .to raise_error(AgentRuns::AppleVerification::NetworkPolicyError, /egress-gateway/)
    end

    it "does not allow callers to alter a resolved destination" do
      snapshot = AgentRuns::EgressPolicy::Snapshot.new(
        mode: "proxy_only",
        egress_profile: "locked",
        destinations: [ { "host" => "api.example.com", "port" => 8443, "scheme" => "https" } ],
        required_destinations: [
          { "host" => "egress-gateway", "port" => 3128, "reason" => "egress_gateway" },
          { "host" => "paid-proxy", "port" => 3000, "reason" => "secrets_proxy" }
        ]
      )

      contract = described_class.from_snapshot(snapshot)

      expect { contract.destinations.first[:host] = "attacker.example.com" }.to raise_error(FrozenError)
    end
  end
end
