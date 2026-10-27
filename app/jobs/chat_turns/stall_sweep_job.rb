# frozen_string_literal: true

class ChatTurns::StallSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_turns_stall_sweep"

  # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002
  def perform
    cutoff = ChatTurn.stall_timeout.ago
    TenantContext.with_system_access do
      ChatTurn.stale_before(cutoff).includes(:chat_session).find_each { |turn| ChatTurns::Lifecycle.stall!(turn:) }
    end
  end
end
