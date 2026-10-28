# frozen_string_literal: true

module ChatSessions
  class DetectStalledTurnsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance
    good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_sessions_detect_stalled_turns")

    def perform
      TenantContext.with_system_access { ChatTurn.detectable.find_each { |turn| detect(turn) } }
    end

    private

    def detect(turn)
      turn.with_lock do
        turn.reload
        return unless turn.status.in?(%w[pending streaming]) && turn.activity_at <= ChatTurn::STALL_AFTER.ago && turn.stallable?

        turn.stall!
        turn.chat_session.messages.create!(role: "system", content: "This turn stopped before the assistant produced a final response. Completed tool activity is preserved below, but the remaining work is unknown. Review any tool confirmation before retrying.", metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id })
        Rails.logger.warn(message: "chat_turn.stalled", chat_turn_id: turn.id, chat_session_id: turn.chat_session_id)
      end
    end
  end
end
