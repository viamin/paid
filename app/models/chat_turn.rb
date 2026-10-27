# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  STALL_THRESHOLD = 15.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, uniqueness: true, allow_nil: true

  scope :awaiting_outcome, -> { where(status: %w[pending streaming]) }
  scope :stale_before, ->(time) { awaiting_outcome.where(last_activity_at: ...time) }

  def pending_confirmation?
    chat_session.messages.pending_tool_confirmations.exists?
  end

  def mark_streaming!
    update!(status: "streaming", last_activity_at: Time.current)
  end

  def complete!
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
  end

  def fail!(classification:)
    update!(status: "failed", failure_classification: classification, last_activity_at: Time.current)
  end
end
