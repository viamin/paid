# frozen_string_literal: true

module Notifications
  module Broadcasting
    private

    def broadcast_notification_updates(account)
      Turbo::StreamsChannel.broadcast_replace_to(
        account, :notification_updates,
        target: "notification_bell",
        partial: "notifications/bell",
        locals: { account: account }
      )

      Turbo::StreamsChannel.broadcast_replace_to(
        account, :notification_updates,
        target: "notification_nav_badges",
        partial: "notifications/nav_badges",
        locals: { account: account }
      )
    end
  end
end
