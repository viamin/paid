# frozen_string_literal: true

module NotificationsHelper
  def unread_notification_count
    return 0 unless current_account

    @_unread_notification_count ||= visible_notifications.active.unread.count
  end

  def notification_badge_counts
    return {} unless current_account

    @_notification_badge_counts ||= visible_notifications.active.unread
      .where.not(nav_section: nil).group(:nav_section).count
  end

  private

  def visible_notifications
    current_account.notifications
      .where(user_id: nil).or(current_account.notifications.where(user_id: current_user&.id))
  end
end
