# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project, paid_state: "manual_review") }

  describe ".call" do
    # @spec ISSUE-REOPEN-REVIEW-005 OPERATOR-INBOX-002D
    it "requires revision-bound validation for a reopened issue" do
      issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

      expect(described_class.call(issue: issue)).to have_attributes(cause: :reopen_review, action: :record_reopen_decision)
    end

    # @spec OPERATOR-INBOX-002D
    it "reuses active work before proposing recovery" do
      run = create(:agent_run, project: project, issue: issue, status: "queued")

      expect(described_class.call(issue: issue)).to have_attributes(cause: :active_work, action: :reuse_run, active_run: run)
    end

    # @spec OPERATOR-INBOX-002D
    it "keeps an unresolved dependency as a wait" do
      dependency = create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:issue_dependency, issue: issue, depends_on_issue: dependency)

      recovery = described_class.call(issue: issue)

      expect(recovery).to have_attributes(cause: :dependency, action: :wait_for_dependency)
      expect(recovery.dependencies).to include(dependency)
    end
  end

  describe "#record_reopen_decision!" do
    # @spec ISSUE-REOPEN-REVIEW-005
    it "records the actor, reason, and current revision in the account audit trail" do
      actor = create(:user, account: account)
      issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON, github_updated_at: Time.current)

      described_class.record_reopen_decision!(issue: issue, actor: actor, reason: "Remaining validation is required.", revision: issue.github_updated_at.iso8601)

      event = account.account_activity_events.last
      expect(event).to have_attributes(action: "issue.reopen_review_validated", actor: actor, subject: issue)
      expect(event.metadata).to include("reason" => "Remaining validation is required.", "github_updated_at" => issue.github_updated_at.iso8601)
    end
  end
end
