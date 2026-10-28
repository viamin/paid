# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerificationFinding do
  # @spec LAYERED-VERIFY-017
  it "persists the obligation's stable external identity" do
    finding = create(:layered_verification_finding)

    expect(finding.obligation_external_identity).to eq(finding.obligation.external_identity)
  end

  # @spec LAYERED-VERIFY-015
  it "invalidates the Inbox count when it enters or leaves a counted status" do
    finding = build(:layered_verification_finding)
    account = finding.project.account

    expect(Dashboard::CacheVersion).to receive(:bump).with(account, scope: Dashboard::CacheVersion::INBOX_SCOPE).twice

    finding.save!
    finding.update!(status: "resolved")
  end
end
