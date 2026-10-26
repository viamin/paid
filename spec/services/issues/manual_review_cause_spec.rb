# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ManualReviewCause do
  let(:project) { create(:project) }

  # @spec OPERATOR-INBOX-002N
  it "uses persisted provenance before any inferred recovery path" do
    issue = create(:issue, project: project, paid_state: "manual_review", manual_review_cause: "scanner_verification")

    result = described_class.call(issue)

    expect(result.name).to eq("scanner_verification")
    expect(result.action).to eq("review_scanner_recurrence")
  end

  # @spec OPERATOR-INBOX-002N
  it "keeps an unproven manual-review hold visible as unknown" do
    issue = create(:issue, project: project, paid_state: "manual_review")

    result = described_class.call(issue)

    expect(result.name).to eq("unknown")
    expect(result.action).to eq("investigate_unknown_hold")
  end

  # @spec OPERATOR-INBOX-002N
  it "routes a real unresolved dependency to waiting rather than enhancement" do
    blocker = create(:issue, project: project, github_state: "open")
    issue = create(:issue, project: project, paid_state: "manual_review")
    create(:issue_dependency, issue: issue, depends_on_issue: blocker)

    result = described_class.call(issue)

    expect(result.name).to eq("dependency_blocked")
    expect(result.action).to eq("wait_for_dependency")
  end

  # @spec OPERATOR-INBOX-002N
  it "requires reconciliation when any work is already queued" do
    issue = create(:issue, project: project, paid_state: "manual_review", manual_review_cause: "enhancement")
    run = create(:agent_run, project: project, issue: issue, status: "queued", goal: "enhance_issue")

    result = described_class.call(issue)

    expect(result.active_run).to eq(run)
    expect(result.action).to eq("reconcile_active_run")
  end
end
