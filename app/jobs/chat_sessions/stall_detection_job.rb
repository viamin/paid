# frozen_string_literal: true

module ChatSessions
  class StallDetectionJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_sessions_stall_detection")

    # @spec CHAT-TURN-STALL-001 @spec CHAT-TURN-STALL-002 @spec CHAT-TURN-STALL-003
    def perform(now: Time.current)
      detected = 0
      cutoff = now - ChatTurn.stall_threshold

      TenantContext.with_system_access do
        ChatTurn.due_for_stall_detection(cutoff).find_each do |turn|
          detected += 1 if detect(turn)
        end
      end

      Rails.logger.info(message: "chat_turn.stall_detection_complete", detected_count: detected) if detected.positive?
    end

    private

    def detect(turn)
      turn.with_lock do
        return false unless turn.status.in?(%w[pending streaming])
        return false if excluded?(turn)

        turn.stall!
        notice = turn.chat_session.messages.create!(
          role: "system",
          content: notice_content(turn),
          metadata: {
            "stalled_turn_notice" => true,
            "chat_turn_id" => turn.id,
            "stall_classification" => turn.stall_classification,
            "recovery_action" => "explicit_review_required",
            "side_effecting_tool_completed" => turn.side_effecting_tool_completed
          }
        )
        broadcast(turn.chat_session, notice)
        Rails.logger.warn(
          message: "chat_turn.stalled",
          chat_turn_id: turn.id,
          chat_session_id: turn.chat_session_id,
          classification: turn.stall_classification,
          side_effecting_tool_completed: turn.side_effecting_tool_completed
        )
        true
      end
    rescue ActiveRecord::RecordNotUnique
      false
    end

    def excluded?(turn)
      session = turn.chat_session
      session.rate_limited? || session.messages.pending_tool_confirmations.exists? ||
        turn.metadata["long_running_operation"] == true
    end

    def notice_content(turn)
      completed = turn.side_effecting_tool_completed ? "Some side-effecting tool work may have completed." : "No completed side-effecting tool work is recorded."
      "This chat turn appears to have stalled. #{completed} The transcript and partial tool activity were preserved, but the assistant did not provide a terminal response. Review the tool confirmations and run details before choosing whether to resume or retry; Paid will not replay this turn automatically."
    end

    def broadcast(session, message)
      ActionCable.server.broadcast("chat_session:#{session.id}", {
        type: "message_created",
        message_id: message.id,
        role: message.role,
        stalled_turn_notice: true,
        html: ApplicationController.render(partial: "chat_messages/message", locals: { message: message })
      })
    end
  end
end
