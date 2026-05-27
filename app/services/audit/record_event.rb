# frozen_string_literal: true

module Audit
  class RecordEvent
    def self.call(...)
      new(...).call
    end

    def initialize(action:, actor: nil, subject: nil, metadata: {}, account: nil)
      @action = action
      @actor = actor
      @subject = subject
      @metadata = metadata
      @account = account
    end

    def call
      event = resolved_account.account_activity_events.create!(
        action: action,
        actor: actor,
        subject: subject,
        metadata: metadata
      )

      Rails.logger.info(
        message: "audit.event_recorded",
        action: action,
        account_id: resolved_account.id,
        actor_id: actor&.id,
        subject_type: subject&.class&.name,
        subject_id: subject&.id,
        event_id: event.id
      )

      event
    end

    private

    attr_reader :action, :actor, :subject, :metadata, :account

    def resolved_account
      return account if account.present?

      if subject.respond_to?(:account)
        subject.account
      elsif subject.is_a?(Account)
        subject
      elsif subject.respond_to?(:project) && subject.project.present?
        subject.project.account
      else
        raise ArgumentError, "Cannot resolve account from subject: #{subject&.class&.name}"
      end
    end
  end
end
