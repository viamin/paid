# frozen_string_literal: true

# A durable lifecycle record for one user-initiated chat turn. It deliberately
# records a stalled turn rather than inferring success from a lost stream.
class ChatTurn < ApplicationRecord
  # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-004
  STATUSES = %w[pending streaming pending_confirmation completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze

  belongs_to :chat_session
  belongs_to :initiating_message, class_name: "ChatMessage", optional: true
  belongs_to :actor, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, presence: true, uniqueness: { scope: :chat_session_id }

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :stale_before, ->(time) { active.where(last_activity_at: ..time) }

  def record_activity!(message: nil)
    update!(initiating_message: message || initiating_message, last_activity_at: Time.current)
  end

  def complete!
    update!(status: "completed", classification: nil, last_activity_at: Time.current)
  end

  def await_confirmation!
    update!(status: "pending_confirmation", last_activity_at: Time.current)
  end

  def fail!(classification:)
    update!(status: "failed", classification:, last_activity_at: Time.current)
  end

  def stall!(classification: "no_durable_activity")
    update!(status: "stalled", classification:, detected_stalled_at: Time.current)
  end
end
