# frozen_string_literal: true

module Notifications
  class Resolve
    include Broadcasting

    def self.call(...)
      new(...).call
    end

    def initialize(account:, source:, subject:, user: nil)
      @account = account
      @source = source
      @subject = subject
      @user = user
    end

    def call
      notification = Notification.find_by(
        account: account,
        user: user,
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

    attr_reader :account, :source, :subject, :user
  end
end
