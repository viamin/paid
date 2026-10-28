# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurnsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_sessions_detect_stalled_turns"

    # @spec CHAT-TURN-001, CHAT-TURN-002, CHAT-TURN-003
    def perform
      detected = 0

      TenantContext.with_system_access do
        ChatTurn.stale_before(Time.current - ChatTurn.stall_after).find_each do |turn|
          detected += 1 if classify(turn)
        end
      end

      Rails.logger.info(message: "chat_turn.stall_detection_complete", detected_count: detected) if detected.positive?
    end

    private

    def classify(turn)
      turn.with_lock do
        turn.reload
        return false unless turn.status.in?(ChatTurn::ACTIVE_STATUSES)
        return false if turn.last_activity_at >= Time.current - ChatTurn.stall_after
        return false if excluded_from_stall_detection?(turn)

        metadata = turn.metadata.merge(
          "stall_detected_at" => Time.current.iso8601,
          "side_effecting_tools_completed" => side_effecting_tools_completed?(turn)
        )
        turn.update!(status: "stalled", stalled_at: Time.current, failure_classification: "no_durable_activity", metadata:)
        persist_notice(turn)
        Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id)
        true
      end
    end

    def excluded_from_stall_detection?(turn)
      turn.chat_session.rate_limited? || turn.chat_session.messages.pending_tool_confirmations.exists?
    end

    def side_effecting_tools_completed?(turn)
      turn.chat_session.messages.where(role: "tool").where.not(tool_call_id: nil).exists?
    end

    def persist_notice(turn)
      # @spec CHAT-TURN-004
      turn.chat_session.messages.create!(
        role: "system",
        content: "This turn stopped before a final response was recorded. Completed tool activity is preserved; do not repeat an action unless you have checked its result. Send a new message or review any pending tool confirmations before continuing.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id }
      )
    end
  end
end
