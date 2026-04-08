# frozen_string_literal: true

module Notifications
  class Resolve
    def self.call(...)
      new(...).call
    end

    def initialize(account:, source:, subject:)
      @account = account
      @source = source
      @subject = subject
    end

    def call
      notification = Notification.find_by(
        account: account,
        source: source,
        subject: subject,
        resolved_at: nil
      )

      return unless notification

      notification.update!(resolved_at: Time.current)
      broadcast
      notification
    end

    private

    attr_reader :account, :source, :subject

    def broadcast
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
