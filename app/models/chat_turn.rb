# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATES = %w[pending streaming completed failed stalled abandoned awaiting_confirmation].freeze
  STALL_TIMEOUT = 10.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :state, inclusion: { in: STATES }
  validates :user_message_id, uniqueness: true

  scope :incomplete, -> { where(state: %w[pending streaming]) }
  scope :stale, ->(now = Time.current) { incomplete.where(activity_at: ..(now - STALL_TIMEOUT)) }
  scope :for_visible_sessions, ->(user) { where(chat_session: ChatSessionPolicy::Scope.new(user, ChatSession).resolve) }

  def mark_streaming!
    update!(state: "streaming", activity_at: Time.current)
  end

  def completed?
    state == "completed"
  end

  def awaiting_confirmation?
    state == "awaiting_confirmation"
  end

  def touch_activity!
    touch(:activity_at)
  end

  def complete!
    update!(state: "completed", activity_at: Time.current)
  end

  def await_confirmation!
    update!(state: "awaiting_confirmation", activity_at: Time.current)
  end

  def fail!(classification:)
    update!(state: "failed", classification:, activity_at: Time.current)
  end

  def stall!
    update!(state: "stalled", classification: "inactivity", detected_at: Time.current, activity_at: Time.current)
  end
end
