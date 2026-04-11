# frozen_string_literal: true

module Notifications
  module Broadcasting
    private

    def broadcast_notification_updates(account)
      # Compute counts here because Devise helpers (current_user, current_account)
      # are unavailable in broadcast/background contexts.
      # Account-wide broadcasts show only account-wide (user_id: nil) notifications,
      # since we cannot know which user is viewing the page.
      account_notifications = Notification.where(account: account, user_id: nil)
      active_unread = account_notifications.active.unread
      unread_count = active_unread.count
      badge_counts = active_unread.where.not(nav_section: nil).group(:nav_section).count

      Turbo::StreamsChannel.broadcast_replace_to(
        account, :notification_updates,
        target: "notification_bell",
        partial: "notifications/bell",
        locals: { account: account, unread_count: unread_count }
      )

      Turbo::StreamsChannel.broadcast_replace_to(
        account, :notification_updates,
        target: "notification_nav_badges",
        partial: "notifications/nav_badges",
        locals: { account: account, badge_counts: badge_counts }
      )
    end
  end
end
