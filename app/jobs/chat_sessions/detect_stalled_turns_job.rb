# frozen_string_literal: true

class ChatSessions::DetectStalledTurnsJob < ApplicationJob
  queue_as :maintenance

  # @spec CHAT-TURN-RECOVERY-001
  def perform
    TenantContext.with_system_access { ChatSessions::DetectStalledTurns.call }
  end
end
