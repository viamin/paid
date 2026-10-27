# frozen_string_literal: true

class ChatSessions::DetectStalledTurnsJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance
  good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_sessions_detect_stalled_turns"

  # @spec CHAT-TURN-LIFECYCLE-001
  def perform
    detected = 0
    TenantContext.with_system_access do
      ChatTurn.stale_before(ChatTurn.stall_threshold.ago).find_each do |turn|
        detected += 1 if ChatSessions::DetectStalledTurn.call(chat_turn: turn)
      end
    end
    Rails.logger.info(message: "chat_turn.stall_detection_complete", detected_count: detected)
  end
end
