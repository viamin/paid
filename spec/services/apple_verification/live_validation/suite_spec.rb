# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-LIVE-001
RSpec.describe AppleVerification::LiveValidation::Suite do
  let(:criteria) { described_class::CRITERIA }

  it "covers every #3978 acceptance criterion with at least one scenario" do
    expect(criteria.keys).to contain_exactly("AC1", "AC2", "AC3", "AC4", "AC5", "AC6", "AC7", "AC8")
  end

  it "describes each criterion in issue terms" do
    expect(criteria.fetch("AC1")).to include("smoke iOS app")
    expect(criteria.fetch("AC2")).to include("ColorMatching-iOS")
    expect(criteria.fetch("AC3")).to include("native macOS GUI")
    expect(criteria.fetch("AC4")).to include("Cancellation")
    expect(criteria.fetch("AC5")).to include("keychain")
    expect(criteria.fetch("AC6")).to include("proxy override")
    expect(criteria.fetch("AC7")).to include("three active paid-agent containers")
    expect(criteria.fetch("AC8")).to include("docs/rdrs")
  end

  it "assigns every scenario a unique id, criterion, group, and expectation" do
    scenarios = described_class::SCENARIOS

    expect(scenarios.map(&:id).tally.values).to all(eq(1))
    scenarios.each do |scenario|
      expect(scenario.criterion).to be_in(criteria.keys)
      expect(scenario.group).to be_in(%i[functional recovery isolation network_policy capacity reporting])
      expect(scenario.description).to be_present
      expect(scenario.expectation).to be_present
    end
  end

  it "maps each criterion to its scenarios" do
    expect(described_class.for_criterion("AC4").map(&:id)).to contain_exactly(
      "recovery-cancellation", "recovery-timeout", "recovery-control-plane-restart",
      "recovery-host-restart", "recovery-partial-provisioning", "recovery-orphan-discovery"
    )
    expect(described_class.for_criterion("AC6").map(&:id)).to contain_exactly(
      "network-direct-ip", "network-alternate-dns", "network-proxy-override",
      "network-unsupported-protocol", "network-compliant-request"
    )
    expect(described_class.for_criterion("AC5").map(&:id)).to contain_exactly(
      "isolation-host-ssh", "isolation-host-filesystem", "isolation-personal-data",
      "isolation-keychain", "isolation-devices", "isolation-container-runtime"
    )
  end

  it "groups scenarios by group" do
    expect(described_class.group(:functional).map(&:id)).to contain_exactly(
      "functional-smoke-ios-app", "functional-colormatching-ios", "functional-macos-gui-app"
    )
    expect(described_class.group(:capacity).map(&:id)).to eq([ "capacity-alongside-three-agent-containers" ])
    expect(described_class.group(:reporting).map(&:id)).to eq([ "report-archived-under-docs-rdrs" ])
  end
end
