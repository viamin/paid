# frozen_string_literal: true

# @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  STALL_THRESHOLD = 10.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :status, inclusion: { in: STATUSES }

  scope :unfinished, -> { where(status: %w[pending streaming]) }
  scope :stale, ->(now = Time.current) { unfinished.where(activity_at: ..(now - STALL_THRESHOLD)) }

  def awaiting_confirmation?
    metadata["awaiting_confirmation"] == true
  end

  def touch_activity!
    update!(status: "streaming", activity_at: Time.current)
  end

  def complete!
    update!(status: "completed", completed_at: Time.current, activity_at: Time.current)
  end

  def fail!(error)
    update!(status: "failed", classification: error.class.name, activity_at: Time.current)
  end

  def pause_for_confirmation!
    update!(status: "pending", activity_at: Time.current, metadata: metadata.merge("awaiting_confirmation" => true))
  end
end
