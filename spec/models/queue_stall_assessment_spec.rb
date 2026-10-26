# frozen_string_literal: true

require "rails_helper"

# @spec QUEUE-DIAG-005 @spec QUEUE-DIAG-012
RSpec.describe QueueStallAssessment do
  let(:user) { create(:user) }
  let(:account) { user.account }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:issue) { create(:issue, project: project) }

  describe "validations" do
    it "requires a known reason code and outcome" do
      assessment = described_class.new(
        account:, issue:, reason_code: "nonsense", state_digest: "digest", outcome: "nope", assessed_at: Time.current
      )

      expect(assessment).not_to be_valid
      expect(assessment.errors[:reason_code]).to be_present
      expect(assessment.errors[:outcome]).to be_present
    end
  end

  describe "deduplication" do
    it "records one assessment per issue, reason and state digest" do
      described_class.create!(account:, issue:, reason_code: "stale_planning_hold",
        state_digest: "digest", outcome: "observed", assessed_at: Time.current)

      duplicate = described_class.new(account:, issue:, reason_code: "stale_planning_hold",
        state_digest: "digest", outcome: "blocked", assessed_at: Time.current)

      expect(duplicate).not_to be_valid
    end

    it "records a separate assessment for a changed state" do
      described_class.create!(account:, issue:, reason_code: "stale_planning_hold",
        state_digest: "digest", outcome: "observed", assessed_at: Time.current)

      changed = described_class.new(account:, issue:, reason_code: "stale_planning_hold",
        state_digest: "other-digest", outcome: "blocked", assessed_at: Time.current)

      expect(changed).to be_valid
    end
  end

  describe ".latest_per_issue" do
    it "returns the most recent assessment per issue" do
      described_class.create!(account:, issue:, reason_code: "stale_planning_hold",
        state_digest: "old", outcome: "observed", assessed_at: 2.hours.ago)
      described_class.create!(account:, issue:, reason_code: "unresolved_delivery",
        state_digest: "new", outcome: "blocked", assessed_at: Time.current)

      latest = described_class.latest_per_issue([ issue.id ])

      expect(latest.map(&:reason_code)).to eq([ "unresolved_delivery" ])
    end

    it "does not present a failed recovery as the last successful assessment" do
      described_class.create!(account:, issue:, reason_code: "stale_planning_hold",
        state_digest: "successful", outcome: "blocked", assessed_at: 2.hours.ago)
      described_class.create!(account:, issue:, reason_code: "unresolved_delivery",
        state_digest: "failed", outcome: "failed", assessed_at: Time.current)

      latest = described_class.latest_per_issue([ issue.id ])

      expect(latest.map(&:state_digest)).to eq([ "successful" ])
    end
  end
end
