# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260412165456_add_review_goal_retry_reset_at_to_issues")

RSpec.describe AddReviewGoalRetryResetAtToIssues, :aggregate_failures do
  let(:migration) { described_class.new }

  it "is reversible and backfills existing issues on re-apply" do
    issue = create(:issue)
    issue.update_column(:review_goal_retry_reset_at, nil)

    migration.down
    Issue.reset_column_information
    expect(Issue.column_names).not_to include("review_goal_retry_reset_at")

    freeze_time do
      migration.up
      Issue.reset_column_information

      expect(Issue.column_names).to include("review_goal_retry_reset_at")
      expect(issue.reload.review_goal_retry_reset_at).to be_within(1.second).of(Time.current)
    end
  end
end
