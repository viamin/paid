# frozen_string_literal: true

class ChatSessions::DetectStalledTurnsJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance
  good_job_control_concurrency_with total_limit: 1, enqueue_limit: 1, key: "chat_sessions_detect_stalled_turns"

  # @spec CHAT-TURN-RECOVERY-003
  def perform
    TenantContext.with_system_access do
      ChatTurn.open.includes(chat_session: :account).find_each do |turn|
        TenantContext.with(turn.chat_session.account) { ChatSessions::Turns::DetectStalled.call(turn:) }
      end
    end
  end
end
