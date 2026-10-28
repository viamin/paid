# frozen_string_literal: true

# Durable, server-owned lifecycle for one accepted chat request.
class ChatTurn < ApplicationRecord
  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, uniqueness: true

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :stale_before, lambda { |time|
    pending_confirmation = ChatMessage.where("chat_messages.chat_session_id = chat_turns.chat_session_id")
      .where(tool_status: "pending").arel.exists
    active.joins(:chat_session).where(last_activity_at: ...time)
      .where(chat_sessions: { rate_limited_until: nil }).where.not(pending_confirmation)
  }

  def start!
    update!(status: "streaming", started_at: started_at || Time.current, last_activity_at: Time.current)
  end

  def record_activity!(message: nil)
    update!(user_message: message || user_message, last_activity_at: Time.current)
  end

  def complete!
    update!(status: "completed", last_activity_at: Time.current)
  end

  def fail!(classification:)
    update!(status: "failed", failure_classification: classification, last_activity_at: Time.current)
  end

  def stall!
    update!(status: "stalled", detected_stalled_at: Time.current)
  end
end
