# frozen_string_literal: true

module ChatTurns
  class StallSweepJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance
    good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_turn_stall_sweep")

    def self.stall_threshold
      ENV.fetch("CHAT_TURN_STALL_THRESHOLD_MINUTES", "30").to_i.clamp(5, 1_440).minutes
    end

    # @spec CHAT-API-028 CHAT-API-032
    def perform
      detected = 0
      TenantContext.with_system_access do
        ChatTurn.stall_candidates(self.class.stall_threshold.ago).find_each do |turn|
          detected += 1 if ChatTurns::ClassifyStalled.call(turn:)
        end
      end
      Rails.logger.info(message: "chat_turn.stall_sweep_completed", detected_count: detected)
    end
  end
end
