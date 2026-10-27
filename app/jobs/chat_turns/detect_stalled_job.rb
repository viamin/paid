# frozen_string_literal: true

class ChatTurns::DetectStalledJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance
  good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_turns_detect_stalled")

  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  def perform
    cutoff = ChatTurns::DetectStalled.timeout.ago
    TenantContext.with_system_access do
      ChatTurn.stale_before(cutoff).find_each { |turn| ChatTurns::DetectStalled.call(turn:) }
    end
  end
end
