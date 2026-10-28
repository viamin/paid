# frozen_string_literal: true

module ChatTurns
  class DetectStalledSweepJob < ApplicationJob
    queue_as :maintenance

    DEFAULT_THRESHOLD = 30.minutes

    # @spec CHAT-TURN-RECOVERY-002
    def perform
      threshold = ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", DEFAULT_THRESHOLD.to_i).to_i.seconds
      detected = 0
      TenantContext.with_system_access do
        ChatTurn.inactive_before(threshold.ago).find_each do |turn|
          detected += 1 if DetectStalled.call(turn:)
        end
      end
      Rails.logger.info(message: "chat_turn.stall_sweep_complete", detected_count: detected)
    end
  end
end
