# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurnsJob < ApplicationJob
    queue_as :maintenance

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: "chat_sessions_detect_stalled_turns"
    )

    # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-003
    def perform
      detected = 0

      TenantContext.with_system_access do
        ChatTurn.stale_active.find_each do |turn|
          detected += 1 if ChatSessions::StallTurn.call(turn:)
        end
      end

      Rails.logger.info(message: "chat_turn.stall_detection_complete", detected_count: detected)
    end
  end
end
