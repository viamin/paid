# frozen_string_literal: true

module ChatTurns
  class RecoverJob < ApplicationJob
    queue_as :default

    # @spec CHAT-API-030 CHAT-API-031
    def perform(chat_turn_id:)
      turn = ChatTurn.find(chat_turn_id)
      ChatSessions::SendMessage.call(chat_session: turn.chat_session, actor: turn.recovery_requested_by,
        content: turn.user_message.content, stream_message_id: turn.stream_id)
      turn.reload.update!(recovery_finished_at: Time.current,
        audit_events: turn.audit_events + [ outcome_event("succeeded") ])
    rescue StandardError
      turn&.reload&.update!(recovery_finished_at: Time.current,
        audit_events: turn.audit_events + [ outcome_event("failed") ])
      raise
    end

    private

    def outcome_event(outcome)
      { "event" => "recovery_finished", "outcome" => outcome, "at" => Time.current.iso8601 }
    end

    def tenant_account
      TenantContext.with_system_access { ChatTurn.find_by(id: arguments.first&.dig(:chat_turn_id))&.account }
    end
  end
end
