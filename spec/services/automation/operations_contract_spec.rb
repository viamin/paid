# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-018
RSpec.describe Automation::Operations::ContractCatalog do
  let(:documentation) do
    File.read(Rails.root.join("docs/intent/automation-phases/operations-ownership.md"))
  end

  it "declares a signal source, activation policy, response scope, limits, escalation, and handoff for every capability" do
    expect(described_class).to be_complete
  end

  it "documents every catalogued capability" do
    described_class.capability_names.each do |capability|
      expect(documentation).to include(capability)
    end
  end

  it "states that no autonomous operational remediation is included" do
    expect(documentation).to include("No autonomous operational remediation")
  end

  it "states that an operations handoff does not authorize coding" do
    handoffs = described_class.contracts.map(&:handoff).join(" ")

    expect(handoffs).to include("does not authorize issue preparation or coding")
  end

  it "keeps release and deployment validation behind its own subordinate controls" do
    contract = described_class.contracts.find { |item| item.capability == "release_deployment_validation" }

    expect(contract.activation_policy).to include("release or deployment control")
  end

  it "names the project-independent platform request categories" do
    expect(described_class::PLATFORM_REQUESTS).to include("platform_health", "credential_status", "safety_guards")
  end
end