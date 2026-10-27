# frozen_string_literal: true

class ChatSessions::DetectStalledTurnsJob < ApplicationJob
  queue_as :maintenance

  def perform
    count = TenantContext.with_system_access { ChatTurns::DetectStalled.call }
    Rails.logger.info(message: "chat_turn.stall_detection_complete", stalled_count: count)
  end
end
