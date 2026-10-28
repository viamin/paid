# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurnsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_sessions_detect_stalled_turns")

    # @spec CHAT-API-027
    def perform
      detected = TenantContext.with_system_access { ChatSessions::DetectStalledTurns.call }
      Rails.logger.info(message: "chat_turn.stall_detection_complete", detected_count: detected)
    end
  end
end
