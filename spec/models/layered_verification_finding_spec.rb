# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  it "attaches a repeated observation to the unresolved scoped cause" do # @spec LAYERED-VERIFY-017
    finding = create(:layered_verification_finding)
    attributes = finding.attributes.symbolize_keys.slice(:project_id, :obligation_id, :agent_run_id, :correspondence_claim_type,
      :cause_signature, :source_passages, :claims, :observed_behavior, :limitations, :question, :options, :owner_actions)

    result = described_class.record!(attributes:, observation: { "agent_run_id" => finding.agent_run_id })

    expect(result).to eq(finding)
    expect(result.observations).to contain_exactly({ "agent_run_id" => finding.agent_run_id })
  end

  it "does not resolve a finding when it is deferred" do # @spec LAYERED-VERIFY-016
    finding = create(:layered_verification_finding)

    finding.defer!(reason: "Awaiting the product owner.")

    expect(finding).to be_deferred
    expect(finding.resolved_at).to be_nil
  end
end
