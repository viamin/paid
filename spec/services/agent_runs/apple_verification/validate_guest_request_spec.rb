# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-NETWORK-002
# @spec APPLE-NETWORK-003
RSpec.describe AgentRuns::AppleVerification::ValidateGuestRequest do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:contract) do
    AgentRuns::AppleVerification::GuestContract.new(
      proxy: { host: "paid-proxy", port: 3000 },
      destinations: [ { host: "github.com", port: 443, scheme: "https" }, { host: "api.github.com", port: nil } ],
      egress_profile: "locked"
    )
  end

  def request(**overrides)
    AgentRuns::AppleVerification::GuestNetworkRequest.new(
      host: "github.com", port: 443, scheme: "https", **overrides
    )
  end

  def call(req)
    described_class.call(agent_run: agent_run, contract: contract, request: req)
  end

  it "allows a request matching the contract" do
    expect(call(request)).to be true
  end

  it "allows a request against a destination with no port restriction" do
    expect(call(request(host: "api.github.com", port: 8443))).to be true
  end

  shared_examples "a denied request" do |matched_rule_pattern:|
    it "raises NetworkPolicyError with the network_policy category" do
      expect { call(denied_request) }.to raise_error(AgentRuns::AppleVerification::NetworkPolicyError) { |error|
        expect(error.category).to eq("network_policy")
      }
    end

    it "records a denied EgressSecurityEvent from the apple_guest layer" do
      expect { call(denied_request) }.to raise_error(AgentRuns::AppleVerification::NetworkPolicyError)

      event = EgressSecurityEvent.last
      expect(event.source_layer).to eq("apple_guest")
      expect(event.event_kind).to eq("denied_egress")
      expect(event.agent_run).to eq(agent_run)
      expect(event.matched_rule).to match(matched_rule_pattern)
    end

    it "records an execution audit event for the denial" do
      expect { call(denied_request) }.to raise_error(AgentRuns::AppleVerification::NetworkPolicyError)

      audit_event = ExecutionAuditEvent.where(agent_run: agent_run, event_name: "apple_guest.network_policy.denied").last
      expect(audit_event).to be_present
      expect(audit_event.metadata["decision"]).to eq("denied")
    end
  end

  context "with an unsupported protocol" do
    let(:denied_request) { request(scheme: "ftp") }

    it_behaves_like "a denied request", matched_rule_pattern: /unsupported protocol/

    it "omits the unsupported scheme from both audit writes" do
      expect { call(denied_request) }.to raise_error(AgentRuns::AppleVerification::NetworkPolicyError)

      event = EgressSecurityEvent.last
      expect(event.scheme).to be_nil

      audit_event = ExecutionAuditEvent.where(agent_run: agent_run, event_name: "apple_guest.network_policy.denied").last
      expect(audit_event.metadata["scheme"]).to be_nil
    end

    context "when the rejected scheme carries embedded URL userinfo" do
      let(:denied_request) { request(scheme: "ftp://user:password@host") }

      it "does not persist the raw scheme value into the audit trail" do
        expect { call(denied_request) }.to raise_error(AgentRuns::AppleVerification::NetworkPolicyError)

        event = EgressSecurityEvent.last
        expect(event.scheme).to be_nil
        expect(event.matched_rule).not_to include("password")

        audit_event = ExecutionAuditEvent.where(agent_run: agent_run, event_name: "apple_guest.network_policy.denied").last
        expect(audit_event.metadata["scheme"]).to be_nil
        expect(audit_event.metadata.to_s).not_to include("password")
      end
    end
  end

  context "with an alternate DNS server" do
    let(:denied_request) { request(dns_server: "8.8.8.8") }

    it_behaves_like "a denied request", matched_rule_pattern: /alternate DNS/
  end

  context "with a proxy override" do
    let(:denied_request) { request(proxy_override: "http://evil.example.com:8080") }

    it_behaves_like "a denied request", matched_rule_pattern: /proxy override/
  end

  context "with a direct IP destination" do
    let(:denied_request) { request(host: "93.184.216.34") }

    it_behaves_like "a denied request", matched_rule_pattern: /direct IP/

    it "redacts the raw IP literal from both audit writes" do
      expect { call(denied_request) }.to raise_error(AgentRuns::AppleVerification::NetworkPolicyError)

      event = EgressSecurityEvent.last
      expect(event.destination_host).to eq("[redacted-ip-literal]")
      expect(event.destination_host).not_to eq("93.184.216.34")

      audit_event = ExecutionAuditEvent.where(agent_run: agent_run, event_name: "apple_guest.network_policy.denied").last
      expect(audit_event.metadata["destination_host"]).to eq("[redacted-ip-literal]")
      expect(audit_event.metadata["destination_host"]).not_to eq("93.184.216.34")
    end
  end

  context "with a direct IPv6 destination" do
    let(:denied_request) { request(host: "2001:db8::1") }

    it_behaves_like "a denied request", matched_rule_pattern: /direct IP/

    it "redacts the raw IPv6 literal from both audit writes" do
      expect { call(denied_request) }.to raise_error(AgentRuns::AppleVerification::NetworkPolicyError)

      event = EgressSecurityEvent.last
      expect(event.destination_host).to eq("[redacted-ip-literal]")
      expect(event.destination_host).not_to eq("2001:db8::1")

      audit_event = ExecutionAuditEvent.where(agent_run: agent_run, event_name: "apple_guest.network_policy.denied").last
      expect(audit_event.metadata["destination_host"]).to eq("[redacted-ip-literal]")
      expect(audit_event.metadata["destination_host"]).not_to eq("2001:db8::1")
    end
  end

  context "with a destination outside the contract using an invalid port" do
    let(:denied_request) { request(host: "attacker.example.com", port: 0) }

    it_behaves_like "a denied request", matched_rule_pattern: /not in guest contract/

    it "omits the invalid port instead of failing to persist the denial" do
      expect { call(denied_request) }.to raise_error(AgentRuns::AppleVerification::NetworkPolicyError)

      event = EgressSecurityEvent.last
      expect(event.destination_port).to be_nil

      audit_event = ExecutionAuditEvent.where(agent_run: agent_run, event_name: "apple_guest.network_policy.denied").last
      expect(audit_event.metadata["destination_port"]).to be_nil
    end
  end

  context "with a destination outside the contract" do
    let(:denied_request) { request(host: "attacker.example.com") }

    it_behaves_like "a denied request", matched_rule_pattern: /not in guest contract/
  end

  context "with a destination matching the contract host but the wrong port" do
    let(:denied_request) { request(host: "github.com", port: 22) }

    it_behaves_like "a denied request", matched_rule_pattern: /not in guest contract/
  end

  context "with a destination matching the contract host and port but the wrong scheme" do
    let(:denied_request) { request(scheme: "http") }

    it_behaves_like "a denied request", matched_rule_pattern: /not in guest contract/
  end
end
