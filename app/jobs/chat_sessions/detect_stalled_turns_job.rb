# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurnsJob < ApplicationJob
    # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
    queue_as :maintenance

    INACTIVITY_THRESHOLD = ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", 15.minutes.to_i).to_i.seconds

    def perform(now: Time.current)
      detected = 0
      cutoff = now - INACTIVITY_THRESHOLD
      TenantContext.with_system_access do
        ChatTurn.stalled_before(cutoff).find_each do |turn|
          detected += 1 if turn.mark_stalled!(before: cutoff)
        end
      end
      Rails.logger.info(message: "chat_turn.stall_detection_complete", detected_count: detected) if detected.positive?
    end
  end
end
