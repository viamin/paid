# frozen_string_literal: true

module ChatSessions
  class StalledTurnSweepJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_sessions_stalled_turn_sweep"

    # @spec CHAT-TURN-001 CHAT-TURN-002
    def perform
      detected = 0
      TenantContext.with_system_access do
        ChatTurn.where(status: "streaming").find_each do |turn|
          TenantContext.with(turn.chat_session.account) { detected += 1 if ChatTurns::MarkStalled.call(chat_turn: turn) }
        end
      end
      Rails.logger.info(message: "chat_turn.stall_sweep_complete", detected_count: detected) if detected.positive?
    end
  end
end
