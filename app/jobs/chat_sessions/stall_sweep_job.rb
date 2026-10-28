# frozen_string_literal: true

module ChatSessions
  class StallSweepJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance
    good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_sessions_stall_sweep"

    # @spec CHAT-TURN-001 CHAT-TURN-002
    def perform
      stalled = 0
      TenantContext.with_system_access do
        ChatTurn.stale.find_each do |turn|
          next unless turn.stall!

          ChatTurns::StallNotice.call(chat_turn: turn)
          stalled += 1
          Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id,
            side_effecting_tool_completed: turn.side_effecting_tool_completed?)
        end
      end
      Rails.logger.info(message: "chat_turn.stall_sweep_complete", stalled_count: stalled)
    end
  end
end
