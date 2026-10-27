# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurnsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_sessions_detect_stalled_turns"

    # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
    def perform
      cutoff = ChatTurn.stall_threshold.ago
      stalled = 0

      TenantContext.with_system_access do
        ChatTurn.stale_streaming(cutoff).includes(chat_session: :account).find_each do |turn|
          TenantContext.with(turn.chat_session.account) { stalled += 1 if turn.stall_if_eligible!(cutoff:) }
        end
      end

      Rails.logger.info(message: "chat_turn.stall_sweep_complete", stalled_count: stalled, cutoff: cutoff.iso8601)
    end
  end
end
