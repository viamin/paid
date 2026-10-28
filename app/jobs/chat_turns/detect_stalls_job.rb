# frozen_string_literal: true

class ChatTurns::DetectStallsJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance
  good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_turns_detect_stalls")

  # @spec CHAT-TURN-RECOVERY-003
  def perform
    stalled = TenantContext.with_system_access { ChatTurns::DetectStalls.call }
    Rails.logger.info(message: "chat_turn.stall_sweep_complete", stalled_count: stalled.size)
  end
end
