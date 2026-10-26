# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "identifies repeated observations by scoped cause rather than description text" do
    finding = build(:layered_verification_finding, cause_signature: "missing-retry-transition")

    expect(finding).to be_valid
  end
end
