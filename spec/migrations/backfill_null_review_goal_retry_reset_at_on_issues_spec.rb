# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260413193654_backfill_null_review_goal_retry_reset_at_on_issues")

RSpec.describe BackfillNullReviewGoalRetryResetAtOnIssues, :aggregate_failures do
  let(:migration) { described_class.new }

  it "backfills existing NULL retry reset timestamps for restarted PRs only" do
    restarted_pr = create(:issue, :pull_request, pr_review_phase: "restarted")
    unaffected_issue = create(:issue)

    restarted_pr.update_column(:review_goal_retry_reset_at, nil)
    unaffected_issue.update_column(:review_goal_retry_reset_at, nil)

    freeze_time do
      migration.up

      expect(restarted_pr.reload.review_goal_retry_reset_at).to be_within(1.second).of(Time.current)
      expect(unaffected_issue.reload.review_goal_retry_reset_at).to be_nil
    end
  end
end
