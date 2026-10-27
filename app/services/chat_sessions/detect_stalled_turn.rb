# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurn
    def self.call(...)
      new(...).call
    end

    def initialize(chat_turn:, now: Time.current)
      @chat_turn = chat_turn
      @now = now
    end

    def call
      chat_turn.with_lock do
        return false unless stale?

        side_effecting_tools_completed = chat_turn.side_effecting_tools_completed?
        chat_turn.update!(
          status: "stalled",
          detected_stalled_at: now,
          failure_classification: "no_durable_activity",
          metadata: chat_turn.metadata.merge("side_effecting_tools_completed" => side_effecting_tools_completed)
        )
        notice = persist_notice(side_effecting_tools_completed:)
        broadcast_notice(notice)
        Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: chat_turn.id, chat_session_id: chat_turn.chat_session_id,
          last_activity_at: chat_turn.last_activity_at, side_effecting_tools_completed: side_effecting_tools_completed)
        true
      end
    end

    private

    attr_reader :chat_turn, :now

    def stale?
      chat_turn.status.in?(%w[pending streaming]) && chat_turn.last_activity_at < now - ChatTurn.stall_threshold && !chat_turn.pending_confirmation?
    end

    def persist_notice(side_effecting_tools_completed:)
      chat_turn.chat_session.messages.create!(
        role: "system",
        content: "This response stopped before the server recorded a final outcome. Any completed messages and tool results above were preserved, but no completion was recorded. Review the transcript before sending a new request, especially any tool confirmations; do not repeat an action that may already have run.",
        metadata: {
          "stalled_turn_notice" => true,
          "chat_turn_id" => chat_turn.id,
          "failure_classification" => chat_turn.failure_classification,
          "side_effecting_tools_completed" => side_effecting_tools_completed
        }
      )
    end

    def broadcast_notice(notice)
      stream_name = "chat_session:#{chat_turn.chat_session_id}"
      ActionCable.server.broadcast(stream_name, {
        type: "message_created",
        message_id: notice.id,
        role: notice.role,
        stream_message_id: chat_turn.stream_message_id,
        html: ApplicationController.render(partial: "chat_messages/message", locals: { message: notice })
      })
      ActionCable.server.broadcast(stream_name, {
        type: "error",
        message_id: chat_turn.stream_message_id,
        message: "The response needs attention"
      })
    end
  end
end
