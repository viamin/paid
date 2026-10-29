# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::MergeAssessmentHistoryRecorder do
  let(:project) do
    create(:project, auto_merge_mode: "off").tap do |record|
      record.update_columns(owner_reviewer_login: "octocat")
    end
  end
  let(:issue) { create(:issue, :pull_request, project:) }
  let(:fresh) { { "failed" => [], "not_evaluated" => [] } }
  let(:stale) do
    {
      "failed" => [ {
        "signal" => "reviews_fresh",
        "approval_evidence" => {
          "stale_approvals" => [ {
            "approver_login" => "octocat",
            "approved_revision" => "old-sha",
            "current_revision" => "new-sha"
          } ]
        }
      } ],
      "not_evaluated" => []
    }
  end

  # @spec OPERATOR-INBOX-022
  it "records approval, manual-merge pending, invalidation, and reapproval by revision" do
    described_class.call(issue:, previous_snapshot: nil, snapshot: fresh, scanned_at: 3.minutes.ago, head_sha: "old-sha")
    described_class.call(issue:, previous_snapshot: fresh, snapshot: stale, scanned_at: 2.minutes.ago, head_sha: "new-sha")
    described_class.call(issue:, previous_snapshot: stale, snapshot: fresh, scanned_at: 1.minute.ago, head_sha: "new-sha")

    events = InboxHistoryEvent.where(project:).newest_first
    expect(events.pluck(Arel.sql("metadata->>'action'"))).to contain_exactly(
      "Owner approval recorded",
      "Manual merge pending",
      "Approval invalidated by newer revision",
      "Manual merge pending",
      "Owner approval recorded"
    )
    expect(events.find_by!(event_key: "merge-assessment:invalidation:new-sha").occurred_at)
      .to be_between(events.minimum(:occurred_at), events.maximum(:occurred_at))
    expect(events.where(event_key: "merge-assessment:approval:new-sha").count).to eq(1)
    expect(events.find_by!(event_key: "merge-assessment:invalidation:new-sha").revision).to eq("new-sha")
  end

  # @spec OPERATOR-INBOX-022
  it "deduplicates replayed scanner evidence" do
    2.times do
      described_class.call(issue:, previous_snapshot: nil, snapshot: stale, scanned_at: Time.current, head_sha: "new-sha")
    end

    expect(InboxHistoryEvent.where(project:).count).to eq(1)
  end
end
