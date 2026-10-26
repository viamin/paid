# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
  it "keeps a deferred finding unresolved" do
    finding = build(:layered_verification_finding, status: "deferred")

    expect(finding).to be_valid
    expect(finding.status).not_to eq("resolved")
  end
end
