# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurnsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_sessions_detect_stalled_turns")

    # @spec CHAT-TURN-RECOVERY-003 CHAT-TURN-RECOVERY-004
    def perform
      threshold = Integer(ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", 10.minutes.to_i)).seconds.ago
      detected = 0

      TenantContext.with_system_access do
        ChatTurn.stale_before(threshold).find_each do |chat_turn|
          detected += 1 if ChatTurns::Stall.call(chat_turn:)
        end
      end

      Rails.logger.info(message: "chat_turn.stall_detection_complete", detected_count: detected, threshold_at: threshold) if detected.positive?
    end
  end
end
