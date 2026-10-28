# frozen_string_literal: true

# A durable lifecycle record for one user-initiated chat exchange. Transcript
# messages remain the source of conversational content; this record makes the
# absence of a terminal outcome observable and recoverable.
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, uniqueness: { scope: :chat_session_id }, allow_nil: true

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :stale, ->(interval, now = Time.current) { active.where(last_activity_at: ..(now - interval)) }

  def streaming?
    status == "streaming"
  end

  def completed?
    status == "completed"
  end

  def stalled?
    status == "stalled"
  end

  def touch_activity!
    update!(last_activity_at: Time.current) if ACTIVE_STATUSES.include?(status)
  end

  def complete!
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
  end

  def fail!(classification:)
    update!(status: "failed", failed_at: Time.current, failure_classification: classification, last_activity_at: Time.current)
  end
end
