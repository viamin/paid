# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::Queue do # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
  it "shows unresolved verification findings independently of automatic work selection" do
    account = create(:account)
    user = create(:user, :member, account:)
    project = create(:project, account:, created_by: user, auto_pick_enabled: false)
    obligation = LayeredVerificationObligation.create!(
      project:, framework: "lid", external_identity: "CHECKOUT-002", external_revision: "abc123",
      scope_description: "Checkout", approval_state: "unresolved"
    )
    finding = LayeredVerificationFinding.create!(
      project:, obligation:, correspondence_claim_type: "spec_to_code", cause_signature: "duplicate-charge",
      check_limitations: "A remote provider was unavailable.", question: "Choose retry semantics."
    )

    entry = described_class.call(user:, kind: Inbox::Queue::LAYERED_VERIFICATION_FINDING_KIND).sole

    expect(entry).to have_attributes(record: finding, project:, questions: [ "Choose retry semantics." ])
  end
end
