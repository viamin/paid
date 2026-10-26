# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do # @spec LAYERED-VERIFY-017
  let(:obligation) do
    LayeredVerificationObligation.create!(
      project: create(:project), framework: "lid", external_identity: "CHECKOUT-001",
      external_revision: "abc123", scope_description: "Checkout", approval_state: "unresolved"
    )
  end

  let(:attributes) do
    {
      project: obligation.project, obligation:, correspondence_claim_type: "spec_to_code", cause_signature: "missing-idempotency",
      check_limitations: "No production trace was available.", question: "Should retries be idempotent?", observation: { "run" => 1 }
    }
  end

  it "attaches repeated observations to the unresolved finding with the same scoped cause" do
    first = described_class.record!(**attributes)
    second = described_class.record!(**attributes.merge(observation: { "run" => 2 }))

    expect(second).to eq(first)
    expect(first.reload.observations).to eq([ { "run" => 1 }, { "run" => 2 } ])
  end
end
