# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-NETWORK-001
# @spec APPLE-NETWORK-002
# @spec APPLE-NETWORK-003
RSpec.describe AppleVerification::GuestNetworkPolicy do
  subject(:policy) do
    described_class.new(
      agent_run: agent_run,
      snapshot: snapshot,
      proxy_url: "http://paid-egress-proxy.internal:3128",
      dns_server: "paid-dns.internal"
    )
  end

  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:snapshot) do
    AgentRuns::EgressPolicy::Snapshot.new(
      mode: "proxy_restricted",
      destinations: [
        { "host" => "packages.example.com", "port" => 443, "scheme" => "https", "source" => "project_allowlist" },
        { "host" => "*.swift.org", "port" => 443, "source" => "account_allowlist" }
      ],
      required_destinations: []
    )
  end

  before { FeatureFlags.enable!(:apple_verification_workers, project: project) }

  describe "#contract" do
    it "produces a credential-free proxy and DNS enforcement contract" do
      expect(policy.contract).to include(
        "default_route" => "deny",
        "host_services" => "deny",
        "dns" => { "mode" => "paid_only", "server" => "paid-dns.internal" },
        "proxy" => { "url" => "http://paid-egress-proxy.internal:3128", "override" => "blocked" },
        "protocols" => %w[http https]
      )
      expect(policy.contract.to_json).not_to match(/password|token|userinfo/i)
      expect(policy.contract.fetch("destinations").first).to include("scheme" => "https")
    end

    it "rejects proxy credentials and query parameters" do
      expect {
        described_class.new(
          agent_run: agent_run,
          snapshot: snapshot,
          proxy_url: "http://token@paid-egress-proxy.internal:3128",
          dns_server: "paid-dns.internal"
        )
      }.to raise_error(ArgumentError, /credentials/)

      expect {
        described_class.new(
          agent_run: agent_run,
          snapshot: snapshot,
          proxy_url: "http://paid-egress-proxy.internal:3128?token=secret",
          dns_server: "paid-dns.internal"
        )
      }.to raise_error(ArgumentError, /query or fragment/)
    end
  end

  describe "#allow_request!" do
    it "allows an approved dependency domain through Paid DNS and proxy" do
      expect(policy.allow_request!(host: "download.swift.org", port: 443, scheme: "https", dns_server: "paid-dns.internal", proxy_url: "http://paid-egress-proxy.internal:3128")).to be(true)
    end

    it "rejects HTTP when the matching allowlist destination is HTTPS-only" do
      expect {
        policy.allow_request!(host: "packages.example.com", port: 443, scheme: "http", dns_server: "paid-dns.internal", proxy_url: "http://paid-egress-proxy.internal:3128")
      }.to raise_error(AppleVerification::GuestNetworkPolicy::NetworkPolicyError, /destination is not allowed/)
    end

    it "rejects denied domains, direct IPs, alternate DNS, proxy overrides, and unsupported protocols" do
      [
        { host: "denied.example.com", port: 443, scheme: "https", dns_server: "paid-dns.internal", proxy_url: "http://paid-egress-proxy.internal:3128" },
        { host: "198.51.100.10", port: 443, scheme: "https", dns_server: "paid-dns.internal", proxy_url: "http://paid-egress-proxy.internal:3128" },
        { host: "packages.example.com", port: 443, scheme: "https", dns_server: "1.1.1.1", proxy_url: "http://paid-egress-proxy.internal:3128" },
        { host: "packages.example.com", port: 443, scheme: "https", dns_server: "paid-dns.internal", proxy_url: "http://override.internal:3128" },
        { host: "packages.example.com", port: 22, scheme: "ssh", dns_server: "paid-dns.internal", proxy_url: "http://paid-egress-proxy.internal:3128" }
      ].each do |request|
        expect { policy.allow_request!(**request) }.to raise_error(AppleVerification::GuestNetworkPolicy::NetworkPolicyError)
      end
    end

    it "records a safe policy denial with a distinct failure category" do
      expect {
        policy.allow_request!(host: "198.51.100.10", port: 443, scheme: "https", dns_server: "paid-dns.internal", proxy_url: "http://paid-egress-proxy.internal:3128")
      }.to raise_error(AppleVerification::GuestNetworkPolicy::NetworkPolicyError) { |error|
        expect(error.failure_category).to eq("network_policy")
      }

      event = EgressSecurityEvent.last
      expect(event).to have_attributes(source_layer: "apple_guest", destination_host: "blocked-literal")
      expect(event.to_audit_line.to_json).not_to include("198.51.100.10")
    end
  end
end
