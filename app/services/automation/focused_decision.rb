# frozen_string_literal: true

module Automation
  # Idempotent Inbox routing for a failed delegated-work boundary check.
  #
  class FocusedDecision
    # Decision identity is the narrow set of metadata fields that distinguish
    # one boundary failure from another (authorization, boundary, reasons,
    # and the settled-intent group a re-decision re-opens). Equivalent
    # identities collapse into the existing notification — including a
    # dismissed or resolved one, so a repeated equivalent failure never
    # re-prompts the operator. A later failure with a different identity
    # refreshes that same notification so the Inbox always points at the
    # authorization, boundary, and reasons that currently block the work.
    IDENTITY_KEYS = %w[authorization_id boundary reasons group_key].freeze

    def self.call(account:, subject:, source:, title:, description:, metadata:)
      notification = Notification.find_by(account:, source:, subject:)
      return notification if notification&.persisted? && same_identity?(notification.metadata, metadata)

      publish(account:, subject:, source:, title:, description:, metadata:)
    rescue ActiveRecord::RecordNotUnique
      # Concurrent rechecks can both initialize a row; the account-wide
      # dedup index (user_id IS NULL) admits only one. Reload the winner and
      # refresh it so the latest failure is represented exactly once.
      notification = Notification.find_by(account:, source:, subject:)
      return notification if notification && same_identity?(notification.metadata, metadata)

      publish(account:, subject:, source:, title:, description:, metadata:)
    end

    def self.publish(account:, subject:, source:, title:, description:, metadata:)
      Notifications::Publish.call(
        account:,
        subject:,
        source:,
        severity: :error,
        blocking: true,
        nav_section: "projects",
        title:,
        description:,
        metadata:
      )
    end

    def self.same_identity?(current, fresh)
      identity(current) == identity(fresh)
    end

    def self.identity(metadata)
      metadata.to_h.slice(*IDENTITY_KEYS)
    end

    private_class_method :publish, :same_identity?, :identity
  end
end
