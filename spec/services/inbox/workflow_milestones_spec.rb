# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::WorkflowMilestones do
  let(:project) { create(:project, tdd_mode: "strict", auto_merge_mode: "off") }
  let(:issue) { create(:issue, :pull_request, project:, github_number: 21, pr_review_phase: "ready", last_scanned_head_sha: "head-sha") }

  def entry(kind:, guidance: nil)
    Inbox::Queue::Entry.new(id: "#{kind}:#{issue.id}", kind:, project:, issue:, guidance:)
  end

  it "separates approved code review from the manual merge action" do # @spec OPERATOR-INBOX-022
    projection = described_class.call(entry(kind: Inbox::Queue::MERGE_APPROVAL_KIND, guidance: {
      instruction: "Review the current changes and make the manual merge decision on GitHub.",
      automatic_merge_active: false, blockers: []
    }))

    expect(projection[:current_action]).to eq("Review the current changes and make the manual merge decision on GitHub.")
    expect(projection[:milestones]).to include(a_hash_including(name: "Owner approval", state: "completed"))
    expect(projection[:milestones]).to include(a_hash_including(name: "Merge", state: "current", label: "Your next step"))
  end

  it "shows the strict-TDD review gate before implementation" do # @spec OPERATOR-INBOX-022
    projection = described_class.call(entry(kind: Inbox::Queue::TEST_REVIEW_PENDING_KIND))

    expect(projection[:milestones]).to include(a_hash_including(name: "Tests", state: "current", label: "Review tests"))
    expect(projection[:milestones]).to include(a_hash_including(name: "Implementation", state: "waiting"))
  end

  it "marks stale approval separately from the manual merge decision" do # @spec OPERATOR-INBOX-022
    projection = described_class.call(entry(kind: Inbox::Queue::MERGE_APPROVAL_KIND, guidance: {
      instruction: "Re-approve the current revision, then make the manual merge decision on GitHub.",
      stale_approval: true, automatic_merge_active: false,
      approval_evidence: { "current_revision" => "new-sha" }, blockers: [ { "signal" => "reviews_fresh" } ]
    }))

    expect(projection[:milestones]).to include(a_hash_including(name: "Owner approval", state: "stale", revision: "new-sha"))
    expect(projection[:milestones]).to include(a_hash_including(name: "Merge", state: "current"))
  end
end
