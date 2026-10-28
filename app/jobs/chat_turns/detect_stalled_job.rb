# frozen_string_literal: true

class ChatTurns::DetectStalledJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_turns_detect_stalled")

  # @spec CHAT-API-027
  def perform
    TenantContext.with_system_access { ChatTurns::DetectStalled.call }
  end
end
