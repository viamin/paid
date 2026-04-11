# frozen_string_literal: true

module Notifications
  class Publish
    include Broadcasting

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
        user: user,
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
        resolved_at: nil,
        dismissed_at: nil
      )

      notification.save!
      broadcast_notification_updates(account)
      notification
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

    attr_reader :account, :source, :subject, :severity, :title,
      :description, :metadata, :action_url, :nav_section, :user
  end
end
