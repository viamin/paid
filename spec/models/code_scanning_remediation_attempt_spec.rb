# frozen_string_literal: true

require "rails_helper"

RSpec.describe CodeScanningRemediationAttempt do
  let(:project) { create(:project, default_branch: "main") }
  let(:issue) do
    create(:issue, project: project, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
  end

  describe "statuses" do
    it "rejects statuses outside the canonical set" do
      attempt = build(:code_scanning_remediation_attempt, issue: issue, status: "bogus")

      expect(attempt).not_to be_valid
      expect(attempt.errors[:status]).to be_present
    end
  end

  describe ".blocking_automation" do
    it "keeps every unresolved verification status out of automatic remediation" do # @spec EAGER-QUEUE-013 @spec EAGER-QUEUE-015
      failed = create(:code_scanning_remediation_attempt, issue: issue, status: "verification_failed")
      awaiting = create(:code_scanning_remediation_attempt, issue: create(:issue, project: project, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE),
        status: "awaiting_verification")
      blocked = create(:code_scanning_remediation_attempt, issue: create(:issue, project: project, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE),
        status: "verification_blocked")
      _fixed = create(:code_scanning_remediation_attempt, issue: create(:issue, project: project, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE),
        status: "verified_fixed")

      ids = described_class.blocking_automation.pluck(:id)

      expect(ids).to contain_exactly(awaiting.id, blocked.id, failed.id)
    end
  end

  describe ".retryable_block" do # @spec EAGER-QUEUE-014
    it "includes attempts that should be revisited by the verifier" do
      awaiting = create(:code_scanning_remediation_attempt, issue: issue, status: "awaiting_verification", pull_request_number: 11)
      blocked = create(:code_scanning_remediation_attempt, issue: issue, status: "verification_blocked", pull_request_number: 12)
      failed_issue = create(:issue, project: project, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
      _failed = create(:code_scanning_remediation_attempt, issue: failed_issue, status: "verification_failed", pull_request_number: 13)
      fixed_issue = create(:issue, project: project, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
      _fixed = create(:code_scanning_remediation_attempt, issue: fixed_issue, status: "verified_fixed", pull_request_number: 14)

      ids = described_class.retryable_block.pluck(:id)

      expect(ids).to contain_exactly(awaiting.id, blocked.id)
    end
  end

  describe ".latest_per_issue" do
    it "returns one attempt per issue, the latest by id" do # @spec EAGER-QUEUE-014 @spec EAGER-QUEUE-015
      older = create(:code_scanning_remediation_attempt, issue: issue, status: "verification_failed", pull_request_number: 21)
      newer = create(:code_scanning_remediation_attempt, issue: issue, status: "verified_fixed", pull_request_number: 22)

      ids = described_class.latest_per_issue.pluck(:id)

      expect(ids).to contain_exactly(newer.id)
      expect(ids).not_to include(older.id)
    end

    it "leaves untouched issues whose only attempt is verified_fixed out of blocking_automation" do
      other_issue = create(:issue, project: project, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
      create(:code_scanning_remediation_attempt, issue: issue, status: "verification_failed",
        pull_request_number: 23, created_at: 2.days.ago)
      create(:code_scanning_remediation_attempt, issue: other_issue, status: "verified_fixed",
        pull_request_number: 24, created_at: 1.day.ago)

      latest_blocking_ids = described_class.blocking_automation.latest_per_issue.pluck(:issue_id)

      expect(latest_blocking_ids).to contain_exactly(issue.id)
    end
  end
end
