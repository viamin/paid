# frozen_string_literal: true

module Notifications
  class Publish
    def self.call(...)
      new(...).call
    end

    def initialize(account:, source:, subject:, severity:, title:, description: nil, metadata: {}, action_url: nil, nav_section: nil, user: nil)
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
    end

    def call
      notification = Notification.find_or_initialize_by(
        account: account,
        source: source,
        subject: subject
      )

      notification.assign_attributes(
        severity: severity,
        title: title,
        description: description,
        metadata: metadata,
        action_url: action_url,
        nav_section: nav_section,
        user: user,
        resolved_at: nil
      )

      notification.save!
      broadcast(notification)
      notification
    end

    private

    attr_reader :account, :source, :subject, :severity, :title,
      :description, :metadata, :action_url, :nav_section, :user

    def broadcast(notification)
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
