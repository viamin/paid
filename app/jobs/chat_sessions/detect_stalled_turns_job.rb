# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurnsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance
    good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_sessions_detect_stalled_turns")

    # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
    def perform
      TenantContext.with_system_access { DetectStalledTurns.call }
    end
  end
end
