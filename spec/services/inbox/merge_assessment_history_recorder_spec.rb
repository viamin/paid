# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Inbox::MergeAssessmentHistoryRecorder do
  let(:project) do
    create(:project, auto_merge_mode: "off").tap do |record|
      record.update_columns(owner_reviewer_login: "octocat")
    end
  end
  let(:issue) { create(:issue, :pull_request, project:) }
  let(:fresh) { { "failed" => [], "not_evaluated" => [] } }
  let(:old_approval) { { "approver_login" => "octocat", "approved_revision" => "old-sha" } }
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
    described_class.call(issue:, previous_snapshot: nil, snapshot: fresh, scanned_at: 3.minutes.ago,
      head_sha: "old-sha", approval_evidence: old_approval)
    described_class.call(issue:, previous_snapshot: fresh, snapshot: stale, scanned_at: 2.minutes.ago, head_sha: "new-sha")
    described_class.call(issue:, previous_snapshot: stale, snapshot: fresh, scanned_at: 1.minute.ago,
      head_sha: "new-sha", approval_evidence: old_approval.merge("approved_revision" => "new-sha"))

    events = InboxHistoryEvent.where(project:).newest_first
    expect(events.pluck(Arel.sql("metadata->>'action'"))).to contain_exactly(
      "Owner approval recorded",
      "Manual merge pending",
      "Approval invalidated by newer revision",
      "Manual merge pending",
      "Owner approval recorded"
    )
    expect(events.find_by!(event_key: "merge-assessment:invalidation:octocat:old-sha:new-sha").occurred_at)
      .to be_between(events.minimum(:occurred_at), events.maximum(:occurred_at))
    expect(events.where(event_key: "merge-assessment:approval:new-sha").count).to eq(1)
    expect(events.find_by!(event_key: "merge-assessment:invalidation:octocat:old-sha:new-sha").revision).to eq("new-sha")
  end

  # @spec OPERATOR-INBOX-022
  it "deduplicates replayed scanner evidence" do
    2.times do
      described_class.call(issue:, previous_snapshot: nil, snapshot: stale, scanned_at: Time.current, head_sha: "new-sha")
    end

    expect(InboxHistoryEvent.where(project:).count).to eq(1)
  end

  # @spec OPERATOR-INBOX-022
  it "records every stale approval independently and deduplicates each replay" do
    stale_approvals = stale.dig("failed", 0, "approval_evidence", "stale_approvals")
    stale_approvals << stale_approvals.first.merge(
      "approver_login" => "reviewer",
      "approved_revision" => "reviewer-sha"
    )

    2.times do
      described_class.call(issue:, previous_snapshot: nil, snapshot: stale,
        scanned_at: Time.current, head_sha: "new-sha")
    end

    events = InboxHistoryEvent.where(project:)
    expect(events.pluck(:actor_label)).to contain_exactly("octocat", "reviewer")
    expect(events.pluck(:event_key)).to contain_exactly(
      "merge-assessment:invalidation:octocat:old-sha:new-sha",
      "merge-assessment:invalidation:reviewer:reviewer-sha:new-sha"
    )
  end

  # @spec OPERATOR-INBOX-022
  it "does not infer owner approval from a blocker-free assessment" do
    described_class.call(issue:, previous_snapshot: nil,
      snapshot: { "failed" => [], "not_evaluated" => [] }, scanned_at: Time.current, head_sha: "new-sha")

    expect(InboxHistoryEvent.where(project:).pluck(Arel.sql("metadata->>'action'")))
      .to contain_exactly("Manual merge pending")
  end

  # @spec OPERATOR-INBOX-002K OPERATOR-INBOX-022
  it "does not record a manual merge event for a trusted per-PR activation" do
    activation_label = project.feature_activation_label_for("auto_merge")
    issue.update!(labels: [ activation_label ])
    github_client = instance_double(GithubClient)
    allow(project).to receive(:client).and_return(github_client)
    allow(github_client).to receive(:issue_events).and_return([ OpenStruct.new(
      event: "labeled",
      actor: OpenStruct.new(login: "viamin"),
      label: OpenStruct.new(name: activation_label),
      created_at: 1.hour.ago
    ) ])

    described_class.call(issue:, previous_snapshot: nil, snapshot: fresh,
      scanned_at: Time.current, head_sha: "new-sha")

    expect(InboxHistoryEvent.where(project:)).to be_empty
  end
end
