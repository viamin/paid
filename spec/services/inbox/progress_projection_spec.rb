# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ProgressProjection do
  def milestone(projection, id)
    projection.to_h.fetch(:milestones).find { |entry| entry.fetch(:id) == id }
  end

  it "keeps an owner-approved docs PR at the manual merge gate" do # @spec INBOX-PROGRESS-001 INBOX-PROGRESS-002
    project = create(:project, auto_merge_mode: "off", tdd_mode: "off")
    pull_request = create(:issue, :pull_request, project:, last_scanned_head_sha: "a" * 40,
      auto_merge_head_sha: "a" * 40,
      auto_merge_evaluated_at: Time.current,
      auto_merge_blockers: { "failed" => [], "not_evaluated" => [] })
    intent = create(:feature_intent, project:)
    create(:feature_intent_design_pr, feature_intent: intent, pull_request_number: pull_request.github_number,
      head_sha: pull_request.last_scanned_head_sha)

    projection = described_class.call(issue: pull_request).to_h

    expect(milestone(projection, "design_approval").fetch(:state)).to eq("not_applicable")
    expect(milestone(projection, "implementation").fetch(:state)).to eq("not_applicable")
    expect(milestone(projection, "owner_approval").fetch(:state)).to eq("complete")
    expect(milestone(projection, "merge")).to include(
      state: "current",
      next_action: "Review the current changes and make the manual merge decision on GitHub."
    )
  end

  it "keeps strict TDD test approval independent from code and owner approval" do # @spec INBOX-PROGRESS-001
    project = create(:project, operating_mode: "human_led_feature_factory", tdd_mode: "strict", auto_merge_mode: "off")
    source_issue = create(:issue, project:)
    intent = create(:feature_intent, :approved_waiting_for_merge, project:)
    create(:feature_intent_issue, feature_intent: intent, issue: source_issue)
    design_pr = create(:feature_intent_design_pr, :merged, feature_intent: intent, head_sha: "d" * 40, reviewed_head_sha: "d" * 40)
    intent.record_approval!(by: project.created_by, pr_heads: { design_pr.pull_request_number.to_s => design_pr.head_sha })
    pull_request = create(:issue, :pull_request, project:, parent_issue: source_issue,
      labels: [ "paid-tests-approved" ], last_scanned_head_sha: "a" * 40,
      tdd_review_head_sha: "a" * 40, auto_merge_head_sha: "a" * 40, auto_merge_evaluated_at: Time.current,
      auto_merge_blockers: { "failed" => [], "not_evaluated" => [] })

    projection = described_class.call(issue: pull_request).to_h

    expect(milestone(projection, "design_approval").fetch(:state)).to eq("complete")
    expect(milestone(projection, "design_release").fetch(:state)).to eq("current")
    expect(milestone(projection, "test_review").fetch(:state)).to eq("complete")
    expect(milestone(projection, "code_review").fetch(:state)).to eq("complete")
    expect(milestone(projection, "owner_approval").fetch(:state)).to eq("complete")
    expect(milestone(projection, "merge").fetch(:state)).to eq("current")
  end

  it "does not carry a design approval across a changed design head" do # @spec INBOX-PROGRESS-002
    project = create(:project, operating_mode: "human_led_feature_factory")
    source_issue = create(:issue, project:)
    intent = create(:feature_intent, :approved_waiting_for_merge, project:)
    create(:feature_intent_issue, feature_intent: intent, issue: source_issue)
    create(:feature_intent_design_pr, feature_intent: intent, head_sha: "b" * 40, reviewed_head_sha: "b" * 40)
    intent.record_approval!(by: project.created_by, pr_heads: { "1" => "a" * 40 })
    pull_request = create(:issue, :pull_request, project:, parent_issue: source_issue)

    expect(milestone(described_class.call(issue: pull_request).to_h, "design_approval")).to include(state: "stale")
  end

  it "reports a requested strict-TDD test revision as blocked and missing current assessment as unknown" do # @spec INBOX-PROGRESS-002
    project = create(:project, tdd_mode: "strict")
    pull_request = create(:issue, :pull_request, project:, labels: [ "paid-test-changes-requested" ],
      last_scanned_head_sha: "a" * 40, tdd_review_head_sha: "a" * 40)

    projection = described_class.call(issue: pull_request).to_h

    expect(milestone(projection, "test_review")).to include(state: "blocked")
    expect(milestone(projection, "owner_approval")).to include(state: "unknown")
  end

  it "blocks merge when an approved test verdict belongs to an earlier head" do # @spec INBOX-PROGRESS-002
    project = create(:project, tdd_mode: "strict")
    pull_request = create(:issue, :pull_request, project:, labels: [ "paid-tests-approved" ],
      pr_review_phase: "ready", last_scanned_head_sha: "b" * 40, tdd_review_head_sha: "a" * 40,
      auto_merge_head_sha: "b" * 40, auto_merge_evaluated_at: Time.current,
      auto_merge_blockers: { "failed" => [], "not_evaluated" => [] })

    projection = described_class.call(issue: pull_request).to_h

    expect(milestone(projection, "test_review")).to include(state: "stale")
    expect(milestone(projection, "implementation")).to include(state: "waiting")
    expect(milestone(projection, "merge")).to include(state: "blocked")
  end

  it "marks implementation and proposed-test review inapplicable for a linked design PR" do # @spec INBOX-PROGRESS-001
    project = create(:project, operating_mode: "human_led_feature_factory", tdd_mode: "strict", auto_merge_mode: "off")
    intent = create(:feature_intent, project:)
    pull_request = create(:issue, :pull_request, project:, github_number: 20, pr_review_phase: "ready",
      last_scanned_head_sha: "a" * 40, auto_merge_head_sha: "a" * 40, auto_merge_evaluated_at: Time.current,
      auto_merge_blockers: { "failed" => [], "not_evaluated" => [] })
    create(:feature_intent_design_pr, feature_intent: intent, pull_request_number: pull_request.github_number,
      head_sha: "a" * 40)

    projection = described_class.call(issue: pull_request).to_h

    expect(milestone(projection, "test_review")).to include(state: "not_applicable")
    expect(milestone(projection, "implementation")).to include(state: "not_applicable")
    expect(milestone(projection, "merge")).to include(state: "current")
  end

  it "projects a released human-led feature without losing the design release label" do # @spec INBOX-PROGRESS-001
    project = create(:project, operating_mode: "human_led_feature_factory")
    source_issue = create(:issue, project:)
    intent = create(:feature_intent, project:)
    create(:feature_intent_issue, feature_intent: intent, issue: source_issue)
    pull_request = create(:issue, :pull_request, project:, parent_issue: source_issue)

    projection = described_class.call(issue: pull_request).to_h

    expect(milestone(projection, "design_release")).to include(label: "Design release", state: "complete")
  end

  it "blocks code review when the current merge assessment has a non-approval blocker" do # @spec INBOX-PROGRESS-001
    project = create(:project)
    pull_request = create(:issue, :pull_request, project:, last_scanned_head_sha: "a" * 40,
      auto_merge_head_sha: "a" * 40,
      auto_merge_evaluated_at: Time.current,
      auto_merge_blockers: { "failed" => [ { "signal" => "ci", "reason" => "Checks failed" } ], "not_evaluated" => [] })

    projection = described_class.call(issue: pull_request).to_h

    expect(milestone(projection, "code_review")).to include(label: "Code review", state: "blocked")
  end

  it "does not carry a merge assessment across a changed head" do # @spec INBOX-PROGRESS-002
    project = create(:project)
    pull_request = create(:issue, :pull_request, project:, last_scanned_head_sha: "b" * 40,
      auto_merge_head_sha: "a" * 40, auto_merge_evaluated_at: Time.current,
      auto_merge_blockers: { "failed" => [], "not_evaluated" => [] })

    projection = described_class.call(issue: pull_request).to_h

    expect(milestone(projection, "code_review")).to include(state: "unknown")
    expect(milestone(projection, "owner_approval")).to include(state: "unknown")
  end

  it "does not report a closed unmerged pull request as merged" do # @spec INBOX-PROGRESS-002
    project = create(:project)
    pull_request = create(:issue, :pull_request, :closed, project:, last_scanned_head_sha: "a" * 40,
      auto_merge_evaluated_at: Time.current,
      auto_merge_blockers: { "failed" => [], "not_evaluated" => [] })

    projection = described_class.call(issue: pull_request).to_h

    expect(milestone(projection, "merge")).to include(
      state: "unknown",
      next_action: "Confirm why the pull request closed without merge evidence."
    )
  end
end
