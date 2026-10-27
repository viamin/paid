# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true
  belongs_to :initiated_by, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, uniqueness: true

  scope :detectable, ->(before) { where(status: %w[pending streaming]).where(activity_at: ..before) }

  def pending_confirmation?
    user_message && chat_session.messages.pending_tool_confirmations.where("created_at >= ?", user_message.created_at).exists?
  end

  # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002
  def record_activity!(message)
    attributes = { activity_at: Time.current }
    attributes[:user_message] = message if message.role == "user" && user_message_id.nil?
    update!(attributes)
  end

  def mark_streaming!
    update!(status: "streaming", activity_at: Time.current) if status == "pending"
  end

  def complete!
    update!(status: "completed", completed_at: Time.current, activity_at: Time.current)
  end

  def fail!(classification:)
    update!(status: "failed", failure_classification: classification, completed_at: Time.current, activity_at: Time.current)
  end

  def stall!
    update!(status: "stalled", stalled_at: Time.current, activity_at: Time.current)
  end
end
