# frozen_string_literal: true

module ChatSessions
  # Detects server-side inactivity, independently of transient browser/SSE
  # state. Only streaming turns qualify; known pauses use durable non-streaming
  # states or the session rate-limit marker.
  class DetectStalledTurnsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: "chat_sessions_detect_stalled_turns"
    )

    # @spec CHAT-TURN-RECOVERY-002
    def perform
      detected = 0

      TenantContext.with_system_access do
        ChatTurn.stale.includes(:chat_session).find_each do |turn|
          next if turn.chat_session.rate_limited?

          detected += 1 if turn.stall!
        end
      end

      Rails.logger.info(message: "chat_turn.stall_detection_complete", detected_count: detected)
    end
  end
end
