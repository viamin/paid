# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurnsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_sessions_detect_stalled_turns")

    # @spec CHAT-TURN-RECOVERY-001, CHAT-TURN-RECOVERY-002, CHAT-TURN-RECOVERY-003
    def perform
      threshold = ChatTurn::STALL_THRESHOLD.ago

      TenantContext.with_system_access do
        ChatTurn.overdue(threshold).find_each { |turn| StallTurn.call(turn: turn, threshold: threshold) }
      end
    end
  end
end
