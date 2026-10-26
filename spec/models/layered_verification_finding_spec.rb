# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "identifies only the same unresolved scoped cause as a duplicate" do
    finding = create(:layered_verification_finding)
    duplicate = build(:layered_verification_finding, project: finding.project, obligation: finding.obligation,
      correspondence_claim_type: finding.correspondence_claim_type, cause_signature: finding.cause_signature)

    expect { duplicate.save! }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
