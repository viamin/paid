# frozen_string_literal: true

require "rails_helper"

# @spec OPERATOR-INBOX-002D
RSpec.describe Inbox::ManualReviewRecovery do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:, github_state: "open", paid_state: "manual_review") }

  describe ".call" do
    it "routes reopen review by its explicit reason" do
      issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

      expect(described_class.call(issue:)).to have_attributes(
        key: "reopen_review", action: "validate_reopen"
      )
    end

    it "routes an unresolved dependency to waiting instead of enhancement" do
      dependency = create(:issue, project:, github_number: 4321, github_state: "open", paid_state: "new")
      create(:issue_dependency, issue:, depends_on_issue: dependency)
      issue.update!(manual_review_reason: "A prior implementation remains incomplete.")

      recovery = described_class.call(issue:)

      expect(recovery).to have_attributes(key: "dependency", action: "wait_for_dependency")
      expect(recovery.dependencies.map(&:label)).to include("#4321")
    end

    it "retains unknown provenance visibly" do
      issue.update!(manual_review_reason: "Operator supplied a reason with no producer record.")

      expect(described_class.call(issue:)).to have_attributes(key: "unknown", action: "investigate")
    end

    it "routes an enhancement run to the existing enhancement retry" do
      create(:agent_run, project:, issue:, goal: "enhance_issue", status: "failed")

      expect(described_class.call(issue:)).to have_attributes(key: "enhancement", action: "retry_enhancement")
    end

    it "recognizes the legacy enhancement round-limit provenance" do
      issue.update!(manual_review_reason: "Round limit reached.")

      expect(described_class.call(issue:).action).to eq("retry_enhancement")
    end
  end
end
