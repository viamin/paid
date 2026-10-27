# frozen_string_literal: true

module ChatSessions
  # Detects lost workers without treating a pending confirmation or a known
  # provider pause as an infrastructure stall. Scheduled every five minutes.
  class DetectStalledTurnsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_sessions_detect_stalled_turns")

    STALL_AFTER = 15.minutes

    # @spec CHAT-TURN-RECOVERY-002
    def perform
      TenantContext.with_system_access do
        ChatTurn.detectable.where("activity_at < ?", STALL_AFTER.ago).find_each do |turn|
          ChatSessions::StallTurn.call(turn: turn)
        end
      end
    end
  end
end
