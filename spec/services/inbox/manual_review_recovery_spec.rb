# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:, paid_state: "manual_review") }

  # @spec OPERATOR-INBOX-002L
  it "classifies the dedicated reopen-review provenance without parsing its copy" do
    issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue:)).to have_attributes(cause: :reopen_review, action: :record_reopen_decision)
  end

  # @spec OPERATOR-INBOX-002L
  it "keeps a real unresolved dependency as a wait instead of requesting enhancement" do
    blocker = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    recovery = described_class.call(issue:)

    expect(recovery).to have_attributes(cause: :dependency, action: :wait_for_dependency)
    expect(recovery.blockers).to contain_exactly(blocker)
  end

  # @spec OPERATOR-INBOX-002L
  it "routes scanner-confirmed recurrence to remediation implementation" do
    create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

    expect(described_class.call(issue:)).to have_attributes(cause: :scanner_recurrence, action: :resume_implementation)
  end

  # @spec OPERATOR-INBOX-002L
  it "retains an unrecognized manual-review reason as visible unknown provenance" do
    issue.update!(manual_review_reason: "A future producer parked this issue.")

    expect(described_class.call(issue:)).to have_attributes(cause: :unknown, action: :none)
  end
end
