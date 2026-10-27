# frozen_string_literal: true

module ChatSessions
  class StalledTurnDetectorJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance
    good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_sessions_stalled_turn_detector"

    # @spec CHAT-TURN-RECOVERY-001
    def perform
      TenantContext.with_system_access { ChatSessions::DetectStalledTurns.call }
    end
  end
end
