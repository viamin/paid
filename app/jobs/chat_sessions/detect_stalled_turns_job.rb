# frozen_string_literal: true

module ChatSessions
  # @spec CHAT-API-028
  class DetectStalledTurnsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_sessions_detect_stalled_turns")

    def perform
      detected = 0

      TenantContext.with_system_access do
        ChatTurn.overdue.find_each do |turn|
          detected += 1 if detect(turn)
        end
      end

      Rails.logger.info(message: "chat_turn.stall_detection_complete", detected_count: detected)
    end

    private

    def detect(turn)
      turn.with_lock do
        return false unless turn.stallable?

        turn.stall!
        persist_notice(turn)
        true
      end
    end

    def persist_notice(turn)
      turn.chat_session.messages.create!(
        role: "system",
        content: "This response stopped before Paid could record a final answer. " \
          "Any completed tool activity remains above; anything after the last recorded activity is unknown. " \
          "Review any tool confirmations before sending a new message to continue. Paid did not replay an action.",
        metadata: { "stalled_turn_notice" => true, "chat_turn_id" => turn.id, "classification" => turn.failure_classification }
      )
    end
  end
end
