# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-018
RSpec.describe Automation::Operations::ContractCatalog do
  let(:documentation) do
    File.read(Rails.root.join("docs/intent/automation-phases/operations-ownership.md"))
  end

  it "declares a signal source, activation policy, response scope, limits, escalation, completion meaning, and handoff for every capability" do
    expect(described_class).to be_complete
  end

  it "documents a completion meaning for every capability" do
    incomplete_contract = described_class::Contract.new(
      **described_class.contracts.first.to_h.merge(completion: " ")
    )

    expect(incomplete_contract).not_to be_complete

    described_class.contracts.each do |contract|
      expect(documentation).to include(contract.completion)
    end
  end

  it "distinguishes shipped capabilities from follow-up scope with concrete evidence" do
    expect(described_class.shipped_capabilities).to include(
      "exception_incident_handling",
      "incident_issue_filing",
      "incident_triage",
      "auto_release_evaluation"
    )
    expect(described_class.follow_up_capabilities).to include(
      "incoming_error_reports",
      "deployment_execution"
    )
    expect(described_class.contracts).to all(have_attributes(evidence: a_string_including("app/")))
  end

  it "documents every catalogued capability" do
    described_class.capability_names.each do |capability|
      expect(documentation).to include(capability)
    end
  end

  it "documents every catalogued evidence reference" do
    described_class.contracts.each do |contract|
      contract.evidence.split("; ").each do |reference|
        expect(documentation).to include(reference)
      end
    end
  end

  it "records the evidence matrix and follow-up boundary in canonical intent" do
    expect(documentation).to include("## Shipped capability evidence")
    expect(documentation).to include("## Explicit follow-up scope")
    expect(documentation).to include("Completion meaning")
    expect(documentation).to include("RDR-075")
    expect(documentation).to include("RDR-076")
  end

  it "states that no autonomous operational remediation is included" do
    expect(documentation).to include("No autonomous operational remediation")
  end

  it "states that an operations handoff does not authorize coding" do
    handoffs = described_class.contracts.map(&:handoff).join(" ")

    expect(handoffs).to include("does not authorize issue preparation or coding")
  end

  it "keeps release and deployment validation behind its own subordinate controls" do
    contract = described_class.contracts.find { |item| item.capability == "auto_release_evaluation" }

    expect(contract.activation_policy).to include("release control")
    expect(described_class.follow_up_capabilities).to include("deployment_execution")
  end

  it "names the project-independent platform request categories" do
    expect(described_class::PLATFORM_REQUESTS).to include("platform_health", "credential_status", "safety_guards")
  end
end
