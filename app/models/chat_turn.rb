# frozen_string_literal: true

# @spec CHAT-TURN-001, CHAT-TURN-002
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :stale_before, ->(time) { active.where(last_activity_at: ...time) }

  def mark_streaming!
    update!(status: "streaming", last_activity_at: Time.current)
  end

  def complete!(status:, classification: nil)
    raise ArgumentError, "status must be terminal" unless %w[completed failed stalled abandoned].include?(status)

    now = Time.current
    update!(status:, classification:, detected_at: (status == "stalled" ? now : detected_at), completed_at: now, last_activity_at: now)
  end

  def stalled?
    status == "stalled"
  end
end
