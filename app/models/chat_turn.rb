# frozen_string_literal: true

class ChatTurn < ApplicationRecord # @spec CHAT-TURN-RECOVERY-001
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true
  belongs_to :checkpoint_message, class_name: "ChatMessage", optional: true

  validates :status, inclusion: { in: STATUSES }

  scope :unfinished, -> { where(status: %w[pending streaming]) }

  def terminal?
    status.in?(%w[completed failed stalled abandoned])
  end

  # Only one worker may execute a browser stream. A duplicate job observes the
  # claimed state and exits before it can re-dispatch a tool.
  def claim_processing! # @spec CHAT-TURN-RECOVERY-005
    self.class.where(id: id, status: "pending").update_all(status: "streaming", updated_at: Time.current).positive?
  end

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
    return false unless user_message_id

    messages = chat_session.messages.pending_tool_confirmations.where("id > ?", user_message_id)
    next_user_message_id = chat_session.messages.where(role: "user").where("id > ?", user_message_id).minimum(:id)
    messages = messages.where("id < ?", next_user_message_id) if next_user_message_id
    messages.exists?
  end
end
