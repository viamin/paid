# frozen_string_literal: true

module NotificationsHelper
  # @spec NOTIFICATION-SEVERITY-004
  def unread_notification_count
    return 0 unless current_account

    @_unread_notification_count ||= visible_notifications.active.unread
      .where(severity: %i[warning error]).count
  end

  private

  def visible_notifications
    NotificationPolicy::Scope.new(current_user, Notification).resolve
  end
end
