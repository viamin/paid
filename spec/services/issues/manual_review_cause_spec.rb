# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ManualReviewCause do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:, paid_state: "manual_review") }

  # @spec MANUAL-REVIEW-RECOVERY-001
  it "keeps an unclassified parked issue visible as unknown without reading its reason prose" do
    issue.update!(manual_review_reason: "enhancement perhaps failed", manual_review_cause: nil)

    classification = described_class.call(issue)

    expect(classification.primary.kind).to eq("unknown")
    expect(classification.reason).to eq("enhancement perhaps failed")
  end

  # @spec MANUAL-REVIEW-RECOVERY-001
  it "reports simultaneous reopen and dependency holds" do
    issue.require_reopen_review!
    blocker = create(:issue, project:, github_state: "open")
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    classification = described_class.call(issue)

    expect(classification.causes.map(&:kind)).to include("reopen_review", "dependency_wait")
    expect(classification.causes.find { |cause| cause.kind == "dependency_wait" }.evidence.fetch("dependencies").first)
      .to include("reference" => "##{blocker.github_number}")
  end
end
