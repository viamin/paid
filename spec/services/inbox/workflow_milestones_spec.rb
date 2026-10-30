# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::WorkflowMilestones do
  let(:project) { create(:project, tdd_mode: "strict", auto_merge_mode: "off") }
  let(:issue) { create(:issue, :pull_request, project:, github_number: 21, pr_review_phase: "ready", last_scanned_head_sha: "head-sha") }

  def entry(kind:, guidance: nil, record: nil)
    Inbox::Queue::Entry.new(id: "#{kind}:#{issue.id}", kind:, project:, issue:, guidance:, record:)
  end

  def escalation(reason)
    Inbox::EscalatedPullRequests::Entry.new(
      pull_request: issue,
      reason:,
      blocked_since: 1.day.ago,
      counters: [],
      last_progress_at: nil,
      operator_paused: false
    )
  end

  it "separates approved code review from the manual merge action" do # @spec OPERATOR-INBOX-023
    projection = described_class.call(entry(kind: Inbox::Queue::MERGE_APPROVAL_KIND, guidance: {
      instruction: "Review the current changes and make the manual merge decision on GitHub.",
      automatic_merge_active: false, blockers: []
    }))

    expect(projection[:current_action]).to eq("Review the current changes and make the manual merge decision on GitHub.")
    expect(projection[:milestones]).to include(a_hash_including(name: "Owner approval", state: "completed"))
    expect(projection[:milestones]).to include(a_hash_including(name: "Merge", state: "current", label: "Your next step"))
  end

  it "keeps manual merge waiting for required owner approval" do # @spec OPERATOR-INBOX-023
    instruction = "Approve the current revision on GitHub."
    projection = described_class.call(entry(kind: Inbox::Queue::MERGE_APPROVAL_KIND, guidance: {
      instruction:, automatic_merge_active: false, blockers: [ { "signal" => "owner_approved" } ]
    }))

    expect(projection[:current_action]).to eq(instruction)
    expect(projection[:milestones]).to include(a_hash_including(name: "Owner approval", state: "current"))
    expect(projection[:milestones]).to include(a_hash_including(name: "Merge", state: "waiting"))
  end

  it "shows the strict-TDD review gate before implementation" do # @spec OPERATOR-INBOX-023
    projection = described_class.call(entry(kind: Inbox::Queue::TEST_REVIEW_PENDING_KIND))

    expect(projection[:milestones]).to include(a_hash_including(name: "Tests", state: "current", label: "Review tests"))
    expect(projection[:milestones]).to include(a_hash_including(name: "Implementation", state: "waiting"))
  end

  it "shows a pending non-strict test review as the current action" do # @spec OPERATOR-INBOX-023
    project.update!(tdd_mode: "non_strict")

    projection = described_class.call(entry(kind: Inbox::Queue::TEST_REVIEW_PENDING_KIND))

    expect(projection[:current_action]).to eq(
      "Review the proposed tests and add paid-tests-approved or paid-test-changes-requested."
    )
    expect(projection[:milestones]).to include(
      a_hash_including(name: "Tests", state: "current", label: "Review tests")
    )
    expect(projection[:milestones]).to include(a_hash_including(name: "Implementation", state: "waiting"))
  end

  it "marks stale approval separately from the manual merge decision" do # @spec OPERATOR-INBOX-023
    projection = described_class.call(entry(kind: Inbox::Queue::MERGE_APPROVAL_KIND, guidance: {
      instruction: "Re-approve the current revision, then make the manual merge decision on GitHub.",
      stale_approval: true, automatic_merge_active: false,
      approval_evidence: { "current_revision" => "new-sha" }, blockers: [ { "signal" => "reviews_fresh" } ]
    }))

    expect(projection[:current_action]).to eq("Re-approve the current revision, then make the manual merge decision on GitHub.")
    expect(projection[:milestones]).to include(
      a_hash_including(name: "Owner approval", state: "stale", revision: "new-sha", current: true)
    )
    expect(projection[:milestones]).to include(a_hash_including(name: "Merge", state: "waiting"))
  end

  it "keeps a stalled draft behind execution recovery" do # @spec OPERATOR-INBOX-023
    instruction = "Review the current changes on GitHub while Paid recovers execution."
    projection = described_class.call(entry(kind: Inbox::Queue::MERGE_APPROVAL_KIND, guidance: {
      instruction:, stalled_execution: true, automatic_merge_active: false, blockers: []
    }))

    expect(projection[:current_action]).to eq(instruction)
    expect(projection[:milestones]).to include(
      a_hash_including(name: "Implementation", state: "blocked", current: true, action: instruction)
    )
    expect(projection[:milestones]).to include(a_hash_including(name: "Code review", state: "waiting"))
    expect(projection[:milestones]).to include(a_hash_including(name: "Owner approval", state: "waiting"))
    expect(projection[:milestones]).to include(a_hash_including(name: "Merge", state: "waiting"))
  end

  it "shows Unblock as the current action for a failure-streak escalation" do # @spec OPERATOR-INBOX-023
    projection = described_class.call(entry(
      kind: Inbox::Queue::ESCALATED_PR_KIND,
      record: escalation(Issue::PR_ESCALATION_REASON_FAILURE_STREAK)
    ))

    expect(projection[:current_action]).to eq("Unblock this pull request.")
    expect(projection[:milestones]).to include(
      a_hash_including(name: "Code review", state: "blocked", current: true, action: "Unblock this pull request.")
    )
    expect(projection[:milestones]).to include(a_hash_including(name: "Owner approval", state: "waiting"))
    expect(projection[:milestones]).to include(a_hash_including(name: "Merge", state: "waiting"))
  end

  it "shows re-approval as the current action for an awaiting-approval escalation" do # @spec OPERATOR-INBOX-023
    projection = described_class.call(entry(
      kind: Inbox::Queue::ESCALATED_PR_KIND,
      record: escalation(Issue::PR_ESCALATION_REASON_AWAITING_APPROVAL)
    ))

    expect(projection[:current_action]).to eq("Re-approve this pull request on GitHub.")
    expect(projection[:milestones]).to include(
      a_hash_including(name: "Owner approval", state: "current", action: "Re-approve this pull request on GitHub.")
    )
    expect(projection[:milestones]).to include(a_hash_including(name: "Merge", state: "waiting"))
  end

  it "omits the pull-request workflow for a non-PR issue-backed lane" do # @spec OPERATOR-INBOX-023
    non_pr_issue = create(:issue, project: project)
    inbox_entry = Inbox::Queue::Entry.new(
      id: "clarifying_questions:#{non_pr_issue.id}",
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND,
      project:,
      issue: non_pr_issue
    )

    expect(described_class.call(inbox_entry)).to eq(current_action: nil, milestones: [])
  end
end
