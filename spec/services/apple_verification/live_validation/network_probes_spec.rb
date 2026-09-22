# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-LIVE-003
RSpec.describe AppleVerification::LiveValidation::NetworkProbes do
  let(:agent_run) { create(:agent_run) }
  let(:contract) do
    AgentRuns::AppleVerification::GuestContract.new(
      proxy: { host: "egress-gateway", port: 3128 },
      destinations: [ { host: "github.com", port: 443, scheme: "https" } ],
      egress_profile: "locked"
    )
  end

  before { FeatureFlags.enable!(:apple_verification_workers, project: agent_run.project) }

  it "denies every adversarial probe through the shipped validator with the expected reason" do
    evidence = described_class.run(agent_run:, contract:)

    denials = evidence.index_by(&:scenario_id)
    expect(denials.fetch("network-direct-ip")).to have_attributes(status: :passed, detail: /direct IP access not permitted/)
    expect(denials.fetch("network-alternate-dns")).to have_attributes(status: :passed, detail: /alternate DNS server not permitted/)
    expect(denials.fetch("network-proxy-override")).to have_attributes(status: :passed, detail: /proxy override not permitted/)
    expect(denials.fetch("network-unsupported-protocol")).to have_attributes(status: :passed, detail: /unsupported protocol/)
  end

  it "permits the compliant control request" do
    evidence = described_class.run(agent_run:, contract:)

    control = evidence.find { |row| row.scenario_id == "network-compliant-request" }
    expect(control.status).to eq(:passed)
    expect(control.detail).to include('permitted')
  end

  it "records audit references for each denial" do
    evidence = described_class.run(agent_run:, contract:)

    denial = evidence.find { |row| row.scenario_id == "network-direct-ip" }
    expect(denial.references).to include(hash_including("kind" => "egress_security_event"))
    expect(denial.references).to include(hash_including("kind" => "execution_audit_event"))

    event = EgressSecurityEvent.find(denial.references.find { |ref| ref["kind"] == "egress_security_event" }.fetch("id"))
    expect(event).to have_attributes(source_layer: "apple_guest", matched_rule: "direct IP access not permitted")
  end

  it "never persists the raw IP literal into the audit reference detail" do
    evidence = described_class.run(agent_run:, contract:)

    denial = evidence.find { |row| row.scenario_id == "network-direct-ip" }
    expect(denial.detail).not_to include("203.0.113.10")
  end

  it "records a failure when an adversarial request is unexpectedly permitted" do
    permissive_validator = ->(**) { true }

    evidence = described_class.run(agent_run:, contract:, validator: permissive_validator)

    denial = evidence.find { |row| row.scenario_id == "network-direct-ip" }
    expect(denial.status).to eq(:failed)
    expect(denial.detail).to include('permitted')
  end

  it "records a failure when a compliant control request is denied" do
    message = "apple guest network policy denied: destination not in guest contract"
    denying_validator = ->(**) { raise AgentRuns::AppleVerification::NetworkPolicyError, message }

    evidence = described_class.run(agent_run:, contract:, validator: denying_validator)

    control = evidence.find { |row| row.scenario_id == "network-compliant-request" }
    expect(control.status).to eq(:failed)
  end
end
