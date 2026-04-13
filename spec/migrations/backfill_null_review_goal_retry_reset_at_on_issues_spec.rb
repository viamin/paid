# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260413193654_backfill_null_review_goal_retry_reset_at_on_issues")

RSpec.describe BackfillNullReviewGoalRetryResetAtOnIssues, :aggregate_failures do
  let(:migration) { described_class.new }

  it "backfills existing NULL retry reset timestamps" do
    issue = create(:issue)
    issue.update_column(:review_goal_retry_reset_at, nil)

    freeze_time do
      migration.up

      expect(issue.reload.review_goal_retry_reset_at).to be_within(1.second).of(Time.current)
    end
  end
end
