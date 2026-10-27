# frozen_string_literal: true

class ChatSessions::DetectStalledTurnsJob < ApplicationJob
  queue_as :maintenance

  def perform
    TenantContext.with_system_access do
      ChatTurn.stale_active.find_each { |turn| ChatSessions::DetectStalledTurn.call(chat_turn: turn) }
    end
  end
end
