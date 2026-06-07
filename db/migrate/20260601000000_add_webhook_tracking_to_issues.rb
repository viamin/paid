# frozen_string_literal: true

class AddWebhookTrackingToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :pull_request_review_webhook_at, :datetime,
      comment: "Timestamp of the most recent pull_request_review webhook, used to skip redundant review fetches"
    add_column :issues, :pull_request_webhook_at, :datetime,
      comment: "Timestamp of the most recent pull_request webhook, used to skip redundant PR data fetches"
    add_column :issues, :issue_comment_webhook_at, :datetime,
      comment: "Timestamp of the most recent issue_comment webhook, used to skip redundant comment fetches"
    add_column :issues, :check_suite_webhook_at, :datetime,
      comment: "Timestamp of the most recent check_suite webhook, used to skip redundant check_runs fetches"
    add_column :issues, :check_run_webhook_at, :datetime,
      comment: "Timestamp of the most recent check_run webhook, used to skip redundant check_runs fetches"
  end
end
