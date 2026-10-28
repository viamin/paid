# frozen_string_literal: true

module ChatSessions
  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  class StallDetectorJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_sessions_stall_detector"

    def perform
      detected = 0

      TenantContext.with_system_access do
        ChatTurn.stale_candidates.find_each { |turn| detected += 1 if detect(turn) }
      end

      Rails.logger.info(message: "chat_turn.stall_detection_complete", detected_count: detected)
    end

    private

    def detect(turn)
      turn.with_lock do
        return false unless turn.reload.state.in?(ChatTurn::ACTIVE_STATES)
        return false unless turn.last_activity_at <= ChatTurn::STALL_THRESHOLD.ago
        return false if turn.chat_session.rate_limited?

        turn.stalled!
        broadcast_notice(persist_notice(turn))
        true
      end
    end

    def persist_notice(turn)
      pending = turn.chat_session.messages.pending_tool_confirmations.order(:id).first
      turn.chat_session.messages.create!(
        role: "system",
        content: notice_content(turn, pending),
        metadata: {
          "stalled_turn_notice" => true,
          "chat_turn_id" => turn.id,
          "last_activity_at" => turn.last_activity_at.iso8601,
          "pending_confirmation_id" => pending&.id
        }.compact
      )
    end

    def broadcast_notice(message)
      ActionCable.server.broadcast("chat_session:#{message.chat_session_id}", {
        type: "message_created",
        message_id: message.id,
        role: message.role,
        html: ApplicationController.render(partial: "chat_messages/message", locals: { message: message })
      })
    end

    def notice_content(turn, pending)
      confirmation = pending ? " Review the pending confirmation for `#{pending.tool_name}` before continuing." : ""
      "This chat turn stopped without a terminal response. Its last durable activity was #{turn.last_activity_at.iso8601}; any remaining model or tool work is unknown. " \
        "No tool is being replayed automatically because it may have already run.#{confirmation}"
    end
  end
end
