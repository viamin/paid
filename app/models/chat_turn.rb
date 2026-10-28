# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATES = %w[pending streaming completed failed stalled abandoned].freeze
  INFRASTRUCTURE_CLASSIFICATION = "infrastructure"
  MAX_AUTOMATIC_RECOVERIES = 1

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"
  belongs_to :last_checkpoint_message, class_name: "ChatMessage", optional: true
  has_many :recovery_attempts, class_name: "ChatTurnRecoveryAttempt", dependent: :destroy

  validates :state, inclusion: { in: STATES }
  validates :stream_key, presence: true, uniqueness: true
  validates :user_message_id, uniqueness: true

  scope :inactive_before, ->(time) {
    where(state: %w[pending streaming]).where(last_activity_at: ...time)
      .where(lease_expires_at: nil).or(
        where(state: %w[pending streaming], last_activity_at: ...time, lease_expires_at: ..Time.current)
      )
  }

  STATES.each do |value|
    define_method("#{value}?") { state == value }
  end

  def self.states
    STATES
  end

  # @spec CHAT-TURN-RECOVERY-005
  def automatic_recovery_safe?
    failure_classification == INFRASTRUCTURE_CLASSIFICATION &&
      !side_effects_completed? && recovery_attempts_count < MAX_AUTOMATIC_RECOVERIES
  end

  def awaiting_confirmation?
    pause_reason == "confirmation" && chat_session.messages.pending_tool_confirmations.exists?
  end
end
