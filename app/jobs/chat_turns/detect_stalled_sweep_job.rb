# frozen_string_literal: true

module ChatTurns
  class DetectStalledSweepJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_turns_detect_stalled_sweep")

    # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002
    def perform
      detected = 0
      TenantContext.with_system_access do
        ChatTurn.detectable.where("last_activity_at <= ?", ChatTurns::DetectStalled.default_threshold.ago).find_each do |turn|
          detected += 1 if ChatTurns::DetectStalled.call(turn:)
        end
      end
      Rails.logger.info(message: "chat_turn.stall_sweep_completed", detected_count: detected)
    end
  end
end
