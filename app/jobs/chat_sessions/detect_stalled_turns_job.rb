# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurnsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance
    good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_sessions_detect_stalled_turns"

    def perform
      TenantContext.with_system_access { ChatSessions::DetectStalledTurns.call }
    end
  end
end
