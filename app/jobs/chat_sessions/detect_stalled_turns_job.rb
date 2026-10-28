# frozen_string_literal: true

module ChatSessions
  # @spec CHAT-TURN-002 CHAT-TURN-003
  class DetectStalledTurnsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance
    good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_sessions_detect_stalled_turns"

    def perform
      stalled = 0
      TenantContext.with_system_access do
        ChatTurn.stale_before(Time.current - ChatTurn::STALL_THRESHOLD).find_each do |turn|
          stalled += 1 if TenantContext.with(turn.chat_session.account) { turn.mark_stalled! }
        end
      end
      Rails.logger.info(message: "chat_turn.stall_detection_complete", stalled_count: stalled) if stalled.positive?
    end
  end
end
