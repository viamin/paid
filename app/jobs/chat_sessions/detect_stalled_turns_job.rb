# frozen_string_literal: true

class ChatSessions::DetectStalledTurnsJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance
  STALL_AFTER = 10.minutes

  good_job_control_concurrency_with(total_limit: 1, enqueue_limit: 1, key: "chat_sessions_detect_stalled_turns")

  # @spec CHAT-API-027
  def perform(now: Time.current)
    TenantContext.with_system_access do
      candidate_messages.find_each do |message|
        lifecycle = ChatSessions::TurnLifecycle.new(message)
        next unless lifecycle.eligible_to_stall?(now - STALL_AFTER)

        lifecycle.stall!
        Rails.logger.warn(message: "chat_turn.stalled", chat_session_id: message.chat_session_id, chat_message_id: message.id)
      end
    end
  end

  private

  def candidate_messages
    ChatMessage.where(role: "user")
      .where("metadata -> 'turn' ->> 'status' IN (?)", ChatSessions::TurnLifecycle::ACTIVE_STATUSES)
  end
end
