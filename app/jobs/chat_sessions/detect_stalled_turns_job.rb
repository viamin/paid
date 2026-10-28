# frozen_string_literal: true

module ChatSessions
  # Detects durable chat turns with no known terminal or waiting state.
  class DetectStalledTurnsJob < ApplicationJob
    # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1,
      key: "chat_sessions_detect_stalled_turns"

    STALL_THRESHOLD = 5.minutes

    def perform(now: Time.current)
      detected = 0
      TenantContext.with_system_access do
        ChatTurn.stale_before(now - STALL_THRESHOLD).find_each do |turn|
          detected += 1 if classify(turn)
        end
      end
      Rails.logger.info(message: "chat_turn.stall_sweep_complete", detected_count: detected) if detected.positive?
    end

    private

    def classify(turn)
      turn.with_lock do
        return false unless ChatTurn.stale_before(Time.current - STALL_THRESHOLD).exists?(id: turn.id)

        turn.stall!
        persist_notice(turn)
        Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id)
        true
      end
    end

    def persist_notice(turn)
      turn.chat_session.messages.create!(
        role: "system",
        content: "This response stopped before Paid recorded a final outcome. Earlier messages and tool activity are preserved, but completion is unknown. Review any tool confirmations before retrying.",
        metadata: { "chat_turn_stalled_notice" => true, "chat_turn_id" => turn.id }
      )
    end
  end
end
