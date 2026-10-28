# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  include TenantScoped

  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  PAUSE_REASONS = %w[confirmation rate_limit long_running].freeze
  TERMINAL_STATUSES = %w[completed failed stalled abandoned].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true
  belongs_to :initiated_by, class_name: "User", optional: true
  has_many :messages, class_name: "ChatMessage", dependent: :nullify
  has_many :recovery_attempts, class_name: "ChatTurnRecoveryAttempt", dependent: :destroy

  validates :stream_message_id, presence: true, uniqueness: { scope: :chat_session_id }
  validates :status, inclusion: { in: STATUSES }
  validates :pause_reason, inclusion: { in: PAUSE_REASONS }, allow_nil: true

  scope :stale_candidates, ->(cutoff) {
    where(status: %w[pending streaming], pause_reason: nil, last_activity_at: ...cutoff)
  }

  # @spec CHAT-TURN-RECOVERY-001
  def record_activity!
    update!(status: "streaming", last_activity_at: Time.current) unless terminal?
  end

  # @spec CHAT-TURN-RECOVERY-001
  def complete!
    return false if terminal?

    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
    true
  end

  def pause_for_confirmation!
    update!(status: "pending", pause_reason: "confirmation", last_activity_at: Time.current)
  end

  def fail!(classification)
    return false if terminal?

    update!(status: "failed", classification:, completed_at: Time.current, last_activity_at: Time.current)
    true
  end

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end
end
