# frozen_string_literal: true

module ChatTurns
  class StallSweepJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance
    good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_turn_stall_sweep"

    def perform
      turns = TenantContext.with_system_access { ChatTurn.watchable.where(last_activity_at: ..threshold).find_each.to_a }
      turns.each { |turn| TenantContext.with(turn.chat_session.account) { ChatTurns::Stall.call(turn:) } }
      Rails.logger.info(message: "chat_turn.stall_sweep_complete", detected_count: turns.size)
    end

    private

    def threshold
      ENV.fetch("CHAT_TURN_STALL_THRESHOLD", "15").to_i.minutes.ago
    end
  end
end
