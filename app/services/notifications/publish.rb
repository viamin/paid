# frozen_string_literal: true

module Notifications
  class Publish
    include Broadcasting

    def self.call(...)
      new(...).call
    end

    def initialize(account:, source:, subject:, severity:, title:, description: nil, metadata: {}, action_url: nil, nav_section: nil, user: nil, blocking: false)
      @account = account
      @source = source
      @subject = subject
      @severity = severity
      @title = title
      @description = description
      @metadata = metadata
      @action_url = action_url
      @nav_section = nav_section
      @user = user
      @blocking = blocking
    end

    def call
      notification = Notification.find_or_initialize_by(
        account: account,
        user: user,
        source: source,
        subject: subject
      )

      notification.assign_attributes(
        severity: severity,
        title: title,
        description: description,
        metadata: metadata,
        action_url: resolved_action_url(notification),
        nav_section: nav_section,
        user: user,
        blocking: blocking,
        read_at: nil,
        resolved_at: nil,
        dismissed_at: nil
      )

      notification.save!
      persist_default_action_url!(notification)
      broadcast_notification_updates(account, user: user)
      notification
    rescue ActiveRecord::RecordNotUnique
      retries ||= 0
      retry if (retries += 1) < 3
      raise
    end

    private

    attr_reader :account, :source, :subject, :severity, :title,
      :description, :metadata, :action_url, :nav_section, :user, :blocking

    def resolved_action_url(notification)
      return action_url if action_url.present?
      return unless blocking

      default_action_url(notification) if notification.persisted?
    end

    def persist_default_action_url!(notification)
      return unless blocking
      return if action_url.present?
      return if notification.action_url.present?

      notification.update_column(:action_url, default_action_url(notification))
    end

    def default_action_url(notification)
      "/inbox/action_required:#{notification.id}"
    end
  end
end
