# frozen_string_literal: true

class ResolveOrphanedBlockingParentReviewNotifications < ActiveRecord::Migration[8.1]
  def up
    Notification.where(source: "blocking_parent_issue_review", resolved_at: nil)
      .update_all(resolved_at: Time.current)
  end

  def down
    # This migration is irreversible because we cannot distinguish between
    # notifications resolved by this migration vs. those resolved for other reasons.
    # Reopening all notifications from this source could resurrect notifications
    # that were legitimately resolved elsewhere.
    raise ActiveRecord::IrreversibleMigration, "Cannot reverse notification cleanup - would resurrect legitimately resolved notifications"
  end
end
