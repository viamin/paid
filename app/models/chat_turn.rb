# frozen_string_literal: true

class ChatTurn < ApplicationRecord # @spec CHAT-TURN-RECOVERY-001
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true
  belongs_to :checkpoint_message, class_name: "ChatMessage", optional: true

  validates :status, inclusion: { in: STATUSES }

  scope :unfinished, -> { where(status: %w[pending streaming]) }

  def record_activity!(message: nil)
    update!(last_activity_at: Time.current, checkpoint_message: message || checkpoint_message, status: "streaming")
  end

  def complete!(message: nil)
    update!(
      status: "completed", completed_at: Time.current, last_activity_at: Time.current,
      checkpoint_message: message || checkpoint_message
    )
  end

  def fail!(error)
    update!(
      status: "failed", failed_at: Time.current, last_activity_at: Time.current,
      failure_classification: error.class.name
    )
  end

  def stall!
    update!(status: "stalled", stalled_at: Time.current, last_activity_at: Time.current)
  end

  def awaiting_confirmation?
    chat_session.messages.pending_tool_confirmations.exists?
  end
end
