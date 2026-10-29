# frozen_string_literal: true

module ChatTurns
  # Writes a ChatTurnLifecycleEvent audit row for a stall classification,
  # recovery attempt, or outcome (#4680). Fail-open: an audit-write failure is
  # logged and swallowed rather than aborting the caller's real turn-lifecycle
  # work, mirroring ExecutionAuditEvents::Lifecycle.
  module Lifecycle
    def self.record(event_name:, chat_turn:, actor: nil, metadata: {})
      ChatTurnLifecycleEvent.create!(
        chat_turn: chat_turn,
        chat_session: chat_turn.chat_session,
        event_name: event_name,
        actor: actor,
        metadata: metadata,
        occurred_at: Time.current
      )
    rescue StandardError => e
      Rails.logger.error(
        message: "chat_turns.lifecycle_event_failed",
        chat_turn_id: chat_turn&.id,
        event_name: event_name,
        error_class: e.class.name,
        error: e.message
      )
      nil
    end
  end
end
