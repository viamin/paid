# frozen_string_literal: true

module ChatSessions
  # Scheduled independently of browser connections so a client disconnect
  # cannot leave a persisted turn silently incomplete.
  class DetectStalledTurnsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance
    good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_sessions_detect_stalled_turns"

    # @spec CHAT-TURN-RECOVERY-001
    def perform
      DetectStalledTurns.call
    end
  end
end
