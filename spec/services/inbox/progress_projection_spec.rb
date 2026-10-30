# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ProgressProjection do
  def milestone(projection, id)
    projection.to_h.fetch(:milestones).find { |entry| entry.fetch(:id) == id }
  end

  it "keeps an owner-approved docs PR at the manual merge gate" do
    project = create(:project, auto_merge_mode: "off", tdd_mode: "off")
    pull_request = create(:issue, :pull_request, project:, last_scanned_head_sha: "a" * 40,
      auto_merge_evaluated_at: Time.current, auto_merge_blockers: { "failed" => [], "not_evaluated" => [] })

    projection = described_class.call(issue: pull_request).to_h

    expect(milestone(projection, "design_approval").fetch(:state)).to eq("not_applicable")
    expect(milestone(projection, "implementation").fetch(:state)).to eq("not_applicable")
    expect(milestone(projection, "owner_approval").fetch(:state)).to eq("complete")
    expect(milestone(projection, "merge")).to include(
      state: "current",
      next_action: "Review the current changes and make the manual merge decision on GitHub."
    )
  end

  it "keeps strict TDD test approval independent from code and owner approval" do
    project = create(:project, operating_mode: "human_led_feature_factory", tdd_mode: "strict", auto_merge_mode: "off")
    source_issue = create(:issue, project:)
    intent = create(:feature_intent, :approved_waiting_for_merge, project:)
    create(:feature_intent_issue, feature_intent: intent, issue: source_issue)
    design_pr = create(:feature_intent_design_pr, :merged, feature_intent: intent, head_sha: "d" * 40, reviewed_head_sha: "d" * 40)
    intent.record_approval!(by: project.created_by, pr_heads: { design_pr.pull_request_number.to_s => design_pr.head_sha })
    pull_request = create(:issue, :pull_request, project:, parent_issue: source_issue,
      labels: [ "paid-tests-approved" ], last_scanned_head_sha: "a" * 40,
      auto_merge_evaluated_at: Time.current, auto_merge_blockers: { "failed" => [], "not_evaluated" => [] })

    projection = described_class.call(issue: pull_request).to_h

    expect(milestone(projection, "design_approval").fetch(:state)).to eq("complete")
    expect(milestone(projection, "design_release").fetch(:state)).to eq("current")
    expect(milestone(projection, "test_review").fetch(:state)).to eq("complete")
    expect(milestone(projection, "code_review").fetch(:state)).to eq("complete")
    expect(milestone(projection, "owner_approval").fetch(:state)).to eq("complete")
    expect(milestone(projection, "merge").fetch(:state)).to eq("current")
  end

  it "does not carry a design approval across a changed design head" do
    project = create(:project, operating_mode: "human_led_feature_factory")
    source_issue = create(:issue, project:)
    intent = create(:feature_intent, :approved_waiting_for_merge, project:)
    create(:feature_intent_issue, feature_intent: intent, issue: source_issue)
    create(:feature_intent_design_pr, feature_intent: intent, head_sha: "b" * 40, reviewed_head_sha: "b" * 40)
    intent.record_approval!(by: project.created_by, pr_heads: { "1" => "a" * 40 })
    pull_request = create(:issue, :pull_request, project:, parent_issue: source_issue)

    expect(milestone(described_class.call(issue: pull_request).to_h, "design_approval")).to include(state: "stale")
  end

  it "reports a requested strict-TDD test revision as blocked and missing current assessment as unknown" do
    project = create(:project, tdd_mode: "strict")
    pull_request = create(:issue, :pull_request, project:, labels: [ "paid-test-changes-requested" ], last_scanned_head_sha: "a" * 40)

    projection = described_class.call(issue: pull_request).to_h

    expect(milestone(projection, "test_review")).to include(state: "blocked")
    expect(milestone(projection, "owner_approval")).to include(state: "unknown")
  end
end
