# frozen_string_literal: true

module ChatTurns
  class StallSweepJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance
    good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_turn_stall_sweep")

    # @spec CHAT-TURN-RECOVERY-002
    def perform
      ChatTurns::DetectStalled.call
    end
  end
end
