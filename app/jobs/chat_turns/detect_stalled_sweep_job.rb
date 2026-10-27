# frozen_string_literal: true

class ChatTurns::DetectStalledSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_turns_detect_stalled_sweep")

  # @spec CHAT-TURN-RECOVERY-001
  def perform
    TenantContext.with_system_access { ChatTurns::DetectStalled.call }
  end
end
