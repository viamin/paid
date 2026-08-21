# frozen_string_literal: true

require "rails_helper"

# @spec EGRESS-POLICY-007
RSpec.describe AgentRuns::EgressPolicy::Gateway do
  subject(:gateway) { described_class.new(agent_run: agent_run, backend: backend, snapshot: snapshot, adapter: adapter) }

  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:backend) { instance_double(Containers::Backends::Base, identifier: "local") }
  let(:snapshot) do
    AgentRuns::EgressPolicy::Snapshot.new(
      mode: "proxy_restricted",
      egress_profile: "locked",
      destinations: [
        { "host" => "api.partner.com", "port" => 443, "source" => "project_allowlist", "entry_id" => 7 }
      ],
      required_destinations: [ { "host" => "paid-proxy", "port" => 3000, "source" => "platform" } ]
    )
  end
  let(:adapter) { AgentRuns::EgressPolicy::GatewayAdapters::Docker.new }


  describe "#gateway_url" do
    it "delegates to the active adapter" do
      expect(gateway.gateway_url).to eq("egress-gateway:3128")
    end
  end

  describe "#allowlist_for" do
    it "returns the snapshot destinations in {host:, port:} form" do
      expect(gateway.allowlist_for).to eq([ { host: "api.partner.com", port: 443 } ])
    end

    it "is empty when the snapshot has no destinations" do
      empty = AgentRuns::EgressPolicy::Snapshot.new(
        mode: "proxy_restricted",
        destinations: [],
        required_destinations: []
      )
      gw = described_class.new(agent_run: agent_run, backend: backend, snapshot: empty, adapter: adapter)

      expect(gw.allowlist_for).to eq([])
    end

    it "drops the host key from destinations that lack one" do
      bare = AgentRuns::EgressPolicy::Snapshot.new(
        mode: "proxy_restricted",
        destinations: [ { "port" => 443, "source" => "platform" } ],
        required_destinations: []
      )
      gw = described_class.new(agent_run: agent_run, backend: backend, snapshot: bare, adapter: adapter)

      expect(gw.allowlist_for).to eq([ { port: 443 } ])
    end
  end

  describe "#ensure!" do
    it "delegates setup to the adapter" do
      expect(adapter).to receive(:ensure!).with(agent_run: agent_run, snapshot: snapshot, backend: backend)
      gateway.ensure!
    end

    it "lets the adapter's UnavailableError propagate (fail-closed contract)" do
      allow(adapter).to receive(:ensure!).and_raise(
        AgentRuns::EgressPolicy::Gateway::UnavailableError, "iptables missing"
      )

      expect { gateway.ensure! }.to raise_error(
        AgentRuns::EgressPolicy::Gateway::UnavailableError, /iptables missing/
      )
    end
  end

  describe "#record_denial!" do
    it "creates a structured EgressSecurityEvent with the gateway denials context" do
      entry = create(:egress_allowlist_entry, account: account, host_pattern: "denied.example.com")

      gateway.record_denial!(
        host: "denied.example.com",
        port: 443,
        matched_rule: "allowlist entry 7",
        scheme: "https",
        egress_allowlist_entry: entry
      )

      expect(EgressSecurityEvent.last).to have_attributes(
        event_kind: "denied_egress",
        severity: "warn",
        source_layer: "gateway",
        destination_host: "denied.example.com",
        destination_port: 443,
        scheme: "https",
        matched_rule: "allowlist entry 7",
        agent_run: agent_run,
        egress_allowlist_entry: entry
      )
    end

    it "is callable without a matching allowlist entry (foreign host)" do
      gateway.record_denial!(host: "random.example.com", port: 443, matched_rule: "no matching rule")

      expect(EgressSecurityEvent.last.egress_allowlist_entry).to be_nil
    end
  end
end
