# frozen_string_literal: true

module ChatTurns
  class DetectStalledJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance
    good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_turns_detect_stalled"

    # @spec API-CONVERSATION-DELEGATION-008
    def perform
      detected = TenantContext.with_system_access { ChatTurns::DetectStalled.call }
      Rails.logger.info(message: "chat_turn.stall_sweep_complete", detected_count: detected)
    end
  end
end
