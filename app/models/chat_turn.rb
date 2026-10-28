# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming awaiting_confirmation completed failed stalled abandoned].freeze
  STALL_TIMEOUT = 15.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :status, inclusion: { in: STATUSES }
  validates :user_message_id, uniqueness: true

  scope :stale_at, ->(now = Time.current) { where(status: %w[pending streaming]).where(last_activity_at: ...now - STALL_TIMEOUT) }

  def touch_activity!
    update!(last_activity_at: Time.current)
  end

  def awaiting_confirmation!
    update!(status: "awaiting_confirmation", last_activity_at: Time.current)
  end

  def complete!
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
  end
end
