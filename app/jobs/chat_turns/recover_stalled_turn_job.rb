# frozen_string_literal: true

module ChatTurns
  # Resumes a stalled chat turn (#4680) from its last durable checkpoint.
  # Enqueued either by ChatTurns::StallDetectorJob (bounded automatic
  # recovery, only for a turn that never touched a write tool) or by
  # ChatChannel#recover_stalled_turn (a human's explicit Resume click).
  # Either caller must already hold the recovery claim
  # (ChatTurn#claim_recovery!) before enqueuing this job, so a crashed/retried
  # enqueue cannot start a second concurrent recovery for the same turn.
  class RecoverStalledTurnJob < ApplicationJob
    AuthorizationRevokedError = Class.new(StandardError)

    queue_as :maintenance

    discard_on ActiveRecord::RecordNotFound

    def perform(chat_turn_id:, triggered_by:, actor_id: nil)
      chat_turn = TenantContext.with_system_access { ChatTurn.find(chat_turn_id) }
      chat_session = chat_turn.chat_session
      actor = actor_id && TenantContext.with_system_access { User.find_by(id: actor_id) }

      TenantContext.with(chat_session.account) { recover(chat_turn, chat_session, actor, triggered_by) }
    rescue ActiveRecord::RecordNotFound
      raise
    rescue StandardError => e
      Rails.logger.error(
        message: "chat_turns.recover_job_failed",
        chat_turn_id: chat_turn_id,
        triggered_by: triggered_by,
        error_class: e.class.name,
        error: e.message
      )
    end

    private

    def recover(chat_turn, chat_session, actor, triggered_by)
      return deny_manual_recovery(chat_turn, chat_session) unless recovery_authorized?(chat_session, actor, triggered_by)

      stream_message_id = SecureRandom.uuid
      stream_name = "chat_session:#{chat_session.id}"

      ActionCable.server.broadcast(stream_name, { type: "message_start", message_id: stream_message_id })
      chunk_sequence = 0

      assistant_message = ChatTurns::Resume.call(
        chat_turn: chat_turn,
        actor: actor,
        stream_message_id: stream_message_id,
        on_message_persisted: ->(message, stream_message_id: nil) {
          broadcast_persisted_message(stream_name, message, stream_message_id: stream_message_id)
        },
        on_chunk: ->(chunk) {
          chunk_sequence += 1
          ActionCable.server.broadcast(stream_name, {
            type: "message_chunk", message_id: stream_message_id, content: chunk, sequence: chunk_sequence
          })
        }
      )

      ActionCable.server.broadcast(stream_name, {
        type: "message_complete",
        message_id: stream_message_id,
        tokens: { input: assistant_message&.tokens_input, output: assistant_message&.tokens_output }
      })
      notice = ChatTurns::PersistStallNotice.refresh_after_recovery_success!(chat_turn: chat_turn)
      broadcast_persisted_message(stream_name, notice) if notice

      Rails.logger.info(
        message: "chat_turns.recovered",
        chat_turn_id: chat_turn.id,
        triggered_by: triggered_by,
        recovered: assistant_message.present?
      )
    rescue StandardError, NotImplementedError => e
      handle_recovery_failure(chat_turn, stream_name, stream_message_id, e)
      raise
    end

    # @spec CHAT-TURN-RECOVERY-005
    def recovery_authorized?(chat_session, actor, triggered_by)
      return true unless triggered_by == "manual"
      return false unless actor

      ChatMessagePolicy.new(actor, ChatMessage.new(chat_session: chat_session)).create?
    end

    def deny_manual_recovery(chat_turn, chat_session)
      stream_name = "chat_session:#{chat_session.id}"
      error = AuthorizationRevokedError.new("The requesting user is no longer authorized to resume this conversation")
      chat_turn.fail!(error: error)
      ActionCable.server.broadcast(stream_name, { type: "error", message: error.message })
      notice = ChatTurns::PersistStallNotice.refresh_after_recovery_failure!(chat_turn: chat_turn)
      broadcast_persisted_message(stream_name, notice) if notice
    end

    def handle_recovery_failure(chat_turn, stream_name, stream_message_id, error)
      ActionCable.server.broadcast(stream_name, {
        type: "error",
        message_id: stream_message_id,
        message: "Recovery failed. Send a new message to continue."
      })
      chat_turn.fail!(error: error) unless chat_turn.status == "failed"
      notice = ChatTurns::PersistStallNotice.refresh_after_recovery_failure!(chat_turn: chat_turn)
      broadcast_persisted_message(stream_name, notice) if notice
    end

    def broadcast_persisted_message(stream_name, message, stream_message_id: nil)
      event_type = if message.role == "tool"
        "message_tool_result"
      elsif message.role == "assistant" && message.tool_name.present? && message.content.nil?
        message.pending_confirmation? ? "message_tool_confirmation" : "message_tool_call"
      else
        "message_created"
      end

      ActionCable.server.broadcast(stream_name, {
        type: event_type,
        message_id: message.id,
        role: message.role,
        tool_name: message.tool_name,
        tool_call_id: message.tool_call_id,
        tool_arguments: message.tool_arguments,
        tool_result: message.tool_result,
        fallback_notice: message.fallback_notice?,
        stream_message_id: stream_message_id,
        html: ApplicationController.render(
          partial: "chat_messages/message",
          locals: { message: message }
        )
      })
    end
  end
end
