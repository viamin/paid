# frozen_string_literal: true

module Notifications
  module Broadcasting
    private

    def broadcast_notification_updates(account, user: nil)
      broadcast_account_notification_updates(account)
      broadcast_user_notification_updates(account, user) if user
    end

    def broadcast_account_notification_updates(account)
      # Account-wide broadcasts show only account-wide (user_id: nil) notifications,
      # since we cannot know which user is viewing the page.
      unread_count = Notification.where(account: account, user_id: nil).badging.count

      Turbo::StreamsChannel.broadcast_replace_to(
        account, :notification_updates,
        target: "notification_bell",
        partial: "notifications/bell",
        locals: { account: account, unread_count: unread_count }
      )
    end

    def broadcast_user_notification_updates(account, user)
      # User-scoped notifications (e.g. merge subscriptions) need a separate
      # broadcast to the user's personal stream so the bell badge updates
      # without a page reload.
      user_visible = Notification.where(account: account, user_id: [ nil, user.id ])
      unread_count = user_visible.badging.count

      Turbo::StreamsChannel.broadcast_replace_to(
        user, :notification_updates,
        target: "notification_bell",
        partial: "notifications/bell",
        locals: { account: account, unread_count: unread_count }
      )
    end
  end
end
