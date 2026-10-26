# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::Queue do
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
  it "shows unresolved findings, including deferred findings, in their own lane" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    obligation = create(:layered_verification_obligation, project:)
    finding = create(:layered_verification_finding, project:, obligation:)
    finding.defer!(reason: "Awaiting decision")

    entry = described_class.call(user:, kind: described_class::LAYERED_VERIFICATION_FINDING_KIND).sole

    expect(entry).to have_attributes(record: finding, project:, questions: [ finding.question ])
  end
end
