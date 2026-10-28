# frozen_string_literal: true

# A durable server-side conclusion for one user-initiated chat operation.
# @spec CHAT-API-026 CHAT-API-027
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  STALL_THRESHOLD = 10.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true
  has_many :messages, class_name: "ChatMessage", dependent: :nullify

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, presence: true, uniqueness: { scope: :chat_session_id }

  scope :watchdog_candidates, ->(now = Time.current) { where(status: %w[pending streaming]).where(last_activity_at: ..(now - STALL_THRESHOLD)) }

  def pending_confirmation?
    messages.pending_tool_confirmations.exists?
  end

  def record_activity!(message = nil)
    update!(status: "streaming", last_activity_at: Time.current, user_message: message || user_message)
  end

  def complete!
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
  end

  def fail!(classification)
    update!(status: "failed", failure_classification: classification, completed_at: Time.current, last_activity_at: Time.current)
  end

  def stall!
    with_lock do
      reload
      return false unless status.in?(%w[pending streaming])
      return false if pending_confirmation? || chat_session.rate_limited?

      update!(status: "stalled", stalled_at: Time.current, last_activity_at: Time.current,
        metadata: metadata.merge("stall_detected_at" => Time.current.iso8601))
      true
    end
  end
end
