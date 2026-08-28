# frozen_string_literal: true

module NotificationsHelper
  # @spec NOTIFICATION-SEVERITY-004
  def unread_notification_count
    return 0 unless current_account

    @_unread_notification_count ||= visible_notifications.badging.count
  end

  # @spec NOTIFICATION-SEVERITY-006
  def unread_notifications?
    return false unless current_account

    return @_unread_notifications if defined?(@_unread_notifications)

    @_unread_notifications = visible_notifications.active.unread.exists?
  end

  private

  def visible_notifications
    NotificationPolicy::Scope.new(current_user, Notification).resolve
  end
end
