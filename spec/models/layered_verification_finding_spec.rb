# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "adds an observation to the same unresolved scoped cause" do
    finding = create(:layered_verification_finding)

    repeated = described_class.record_observation!(
      project: finding.project, obligation: finding.obligation, agent_run: finding.agent_run,
      correspondence_claim_type: finding.correspondence_claim_type, cause_signature: finding.cause_signature,
      observed_behavior: finding.observed_behavior, question: finding.question
    )

    expect(repeated).to have_attributes(id: finding.id, observations_count: 2)
  end
end
