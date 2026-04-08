# frozen_string_literal: true

class NotificationsController < ApplicationController
  def index
    authorize Notification
    scope = policy_scope(Notification).visible.recent

    scope = scope.unread if params[:filter] == "unread"
    scope = scope.where(severity: params[:severity]) if params[:severity].present?
    scope = scope.where(source: params[:source]) if params[:source].present?

    @pagy, @notifications = pagy(scope, limit: 25)
  end

  def read
    @notification = policy_scope(Notification).find(params[:id])
    authorize @notification
    @notification.update!(read_at: Time.current)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(@notification, partial: "notifications/notification", locals: { notification: @notification }),
          turbo_stream.replace("notification_bell", partial: "notifications/bell", locals: { account: current_account })
        ]
      end
      format.html { redirect_back(fallback_location: notifications_path) }
    end
  end

  def dismiss
    @notification = policy_scope(Notification).find(params[:id])
    authorize @notification
    @notification.update!(dismissed_at: Time.current)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.remove(@notification),
          turbo_stream.replace("notification_bell", partial: "notifications/bell", locals: { account: current_account })
        ]
      end
      format.html { redirect_back(fallback_location: notifications_path) }
    end
  end

  def mark_all_read
    authorize Notification
    policy_scope(Notification).active.unread.update_all(read_at: Time.current)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace("notification_bell", partial: "notifications/bell", locals: { account: current_account })
      end
      format.html { redirect_to notifications_path, notice: "All notifications marked as read." }
    end
  end
end
