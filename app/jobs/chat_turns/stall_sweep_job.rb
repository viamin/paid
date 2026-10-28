# frozen_string_literal: true

class ChatTurns::StallSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance
  good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_turns_stall_sweep"

  # @spec CHAT-TURN-002
  def perform
    TenantContext.with_system_access { ChatTurns::StallDetector.call }
  end
end
