# frozen_string_literal: true

# @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002
class ChatTurn < ApplicationRecord
  STATES = %w[pending streaming awaiting_confirmation rate_limited completed failed stalled abandoned].freeze
  ACTIVE_STATES = %w[pending streaming].freeze
  STALL_THRESHOLD = 10.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :state, inclusion: { in: STATES }
  validates :user_message_id, uniqueness: true

  scope :stale_candidates, ->(now = Time.current) {
    where(state: ACTIVE_STATES).where(last_activity_at: ..(now - STALL_THRESHOLD))
  }

  def self.for_user_message!(message)
    find_or_create_by!(user_message: message) do |turn|
      turn.chat_session = message.chat_session
      turn.last_activity_at = message.created_at
    end
  end

  def streaming!
    update!(state: "streaming", last_activity_at: Time.current)
  end

  def record_activity!
    update!(last_activity_at: Time.current) if state.in?(ACTIVE_STATES)
  end

  def awaiting_confirmation!
    update!(state: "awaiting_confirmation", last_activity_at: Time.current)
  end

  def rate_limited!
    update!(state: "rate_limited", failure_classification: "rate_limited", last_activity_at: Time.current)
  end

  def completed!
    update!(state: "completed", completed_at: Time.current, last_activity_at: Time.current)
  end

  def failed!(classification)
    update!(state: "failed", failure_classification: classification, last_activity_at: Time.current)
  end

  def stalled!
    update!(state: "stalled", failure_classification: "no_durable_activity", detected_stalled_at: Time.current)
  end
end
