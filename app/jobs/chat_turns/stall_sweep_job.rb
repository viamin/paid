# frozen_string_literal: true

module ChatTurns
  class StallSweepJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance
    good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_turns_stall_sweep"

    # @spec CHAT-TURN-001
    def perform
      TenantContext.with_system_access do
        count = ChatTurns::StallDetector.call
        Rails.logger.info(message: "chat_turn.stall_sweep_complete", stalled_count: count) if count.positive?
      end
    end
  end
end
