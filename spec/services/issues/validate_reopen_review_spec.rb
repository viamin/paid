# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ValidateReopenReview do
  let(:project) { create(:project) }
  let(:actor) { create(:user) }
  let(:issue) { create(:issue, project:, paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON) }

  # @spec ISSUE-REOPEN-REVIEW-005
  it "records an authorized validation bound to the current revision" do
    result = described_class.call(issue:, actor:, reason: "Live validation evidence remains required.", revision: issue.reopen_review_revision)

    expect(result).to be_success
    expect(issue.reload).to have_attributes(reopen_review_validated_by: actor, reopen_review_validation_reason: "Live validation evidence remains required.")
    expect(issue).to be_reopen_review_validated_for_current_revision
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "rejects a stale revision" do
    result = described_class.call(issue:, actor:, reason: "Continue.", revision: "stale")

    expect(result).not_to be_success
    expect(issue.reload.reopen_review_validated_at).to be_nil
  end
end
