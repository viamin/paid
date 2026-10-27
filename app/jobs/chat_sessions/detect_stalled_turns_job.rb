# frozen_string_literal: true

class ChatSessions::DetectStalledTurnsJob < ApplicationJob
  queue_as :maintenance

  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  def perform
    TenantContext.with_system_access { ChatTurns::DetectStalled.call }
  end
end
