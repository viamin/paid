# frozen_string_literal: true

class AddWebhookTrackingToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :pull_request_review_webhook_at, :datetime
    add_column :issues, :pull_request_webhook_at, :datetime
    add_column :issues, :issue_comment_webhook_at, :datetime
    add_column :issues, :check_suite_webhook_at, :datetime
    add_column :issues, :check_run_webhook_at, :datetime
  end
end
