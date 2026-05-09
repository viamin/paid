# frozen_string_literal: true

class ResolveOrphanedBlockingParentReviewNotifications < ActiveRecord::Migration[8.1]
  def up
    Notification.where(source: "blocking_parent_issue_review", resolved_at: nil)
      .update_all(resolved_at: Time.current)
  end

  def down
    Notification.where(source: "blocking_parent_issue_review")
      .where.not(resolved_at: nil)
      .where("resolved_at >= ?", Time.utc(2026, 5, 9))
      .update_all(resolved_at: nil)
  end
end
