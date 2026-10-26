# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "enforces identity independently of the observed revision" do
    obligation = create(:layered_verification_obligation)
    attributes = {
      project: obligation.project,
      obligation: obligation,
      correspondence_claim_type: "spec_to_code",
      cause_signature: "missing-retry-bound",
      question: "Which retry bound is intended?",
      observed_behavior: "The implementation retries indefinitely.",
      limitations: "Only the scoped retry path was inspected."
    }
    described_class.create!(attributes.merge(external_revision: "first"))

    duplicate = described_class.new(attributes.merge(external_revision: "second"))

    expect(duplicate).to be_invalid
    expect(duplicate.errors[:cause_signature]).to include("already has a finding for this cause")
  end
end
