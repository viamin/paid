# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-015
  # @spec LAYERED-VERIFY-016
  it "shows an unresolved finding without treating deferral as resolution" do
    finding = create(:layered_verification_finding, status: "deferred", deferred_reason: "awaiting owner decision")

    snapshot = described_class.call(finding)

    expect(snapshot).to be_present
    expect(snapshot.resolved?).to be(false)
    expect(snapshot.detail.fetch(:consequences)).to be_present
  end
end
