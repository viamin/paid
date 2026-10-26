# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManualReviews::Recovery do
  let(:project) { create(:project) }

  # @spec OPERATOR-INBOX-002K
  it "keeps a reopen-review hold distinct from generic enhancement recovery" do
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    plan = described_class.for(issue: issue)

    expect(plan).to have_attributes(cause: :reopen_review, action: :record_reopen_decision, goal: nil)
  end

  # @spec OPERATOR-INBOX-002K
  it "links a real unresolved dependency instead of offering enhancement" do
    prerequisite = create(:issue, project:, github_state: "open", paid_state: "new")
    issue = create(:issue, project:, paid_state: "manual_review")
    create(:issue_dependency, issue:, depends_on_issue: prerequisite)

    plan = described_class.for(issue: issue)

    expect(plan).to have_attributes(cause: :dependency, action: nil)
    expect(plan.dependencies).to include(prerequisite)
  end

  # @spec OPERATOR-INBOX-002K
  it "keeps an unknown manual-review cause visible rather than guessing a retry" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Legacy stop")

    expect(described_class.for(issue: issue)).to have_attributes(cause: :unknown, action: nil)
  end

  # @spec OPERATOR-INBOX-002K
  it "requires reconciliation when queued work already exists" do
    issue = create(:issue, project:, paid_state: "manual_review")
    run = create(:agent_run, project:, issue:, status: "queued", goal: "create_pr")

    expect(described_class.for(issue: issue)).to have_attributes(cause: :active_work, action: nil, active_run: run)
  end
end
