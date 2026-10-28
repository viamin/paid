# frozen_string_literal: true

module ChatTurns
  class DetectStallsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance
    good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_turns_detect_stalls")

    # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-003
    def perform
      turns = TenantContext.with_system_access { ChatTurns::DetectStalls.call }
      Rails.logger.warn(message: "chat_turns.stalls_detected", count: turns.size, chat_turn_ids: turns.map(&:id)) if turns.any?
    end
  end
end
