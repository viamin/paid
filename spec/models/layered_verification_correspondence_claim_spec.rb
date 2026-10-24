# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationCorrespondenceClaim do
  # @spec LAYERED-VERIFY-007
  it "requires a declared mapping, boundaries, and assumptions without claiming evidence" do
    claim = described_class.new(obligation: create(:layered_verification_obligation))

    expect(claim).to be_invalid
    expect(claim.errors.attribute_names).to include(:claim_type, :source_reference, :target_reference, :abstraction_boundaries, :assumptions)
  end
end
