# frozen_string_literal: true

module Notifications
  class Resolve
    include Broadcasting

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
      broadcast_notification_updates(account)
      notification
    end

    private

    attr_reader :account, :source, :subject
  end
end
