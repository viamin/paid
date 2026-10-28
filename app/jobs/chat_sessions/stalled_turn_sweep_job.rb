# frozen_string_literal: true

module ChatSessions
  class StalledTurnSweepJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance
    good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_sessions_stalled_turn_sweep"

    def perform
      notices = TenantContext.with_system_access { ChatSessions::DetectStalledTurns.call }
      Rails.logger.info(message: "chat_turn.stall_sweep_complete", stalled_count: notices.size)
    end
  end
end
