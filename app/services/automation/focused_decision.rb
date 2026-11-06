# frozen_string_literal: true

module Automation
  # Idempotent Inbox routing for a failed delegated-work boundary check.
  class FocusedDecision
    def self.call(account:, subject:, source:, title:, description:, metadata:)
      notification = Notification.find_or_initialize_by(account:, source:, subject:)
      return notification if notification.persisted? && notification.active?

      notification.assign_attributes(
        severity: :error,
        blocking: true,
        nav_section: "projects",
        title:,
        description:,
        dismissed_at: nil,
        resolved_at: nil,
        metadata:
      )
      notification.save!
      notification
    end
  end
end
