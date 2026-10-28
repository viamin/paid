# frozen_string_literal: true

# Durable execution record for one user-originated chat turn. The transcript
# remains authoritative for content; this record is the lifecycle/audit unit.
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming awaiting_confirmation completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze
  TERMINAL_STATUSES = %w[completed failed stalled abandoned].freeze
  STALL_TIMEOUT = 10.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true
  has_many :chat_messages, dependent: :nullify

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, presence: true, uniqueness: { scope: :chat_session_id }

  scope :stale_active, ->(now = Time.current) { where(status: ACTIVE_STATUSES).where(last_activity_at: ..(now - stall_timeout)) }

  def self.stall_timeout
    Integer(ENV.fetch("CHAT_TURN_STALL_TIMEOUT_SECONDS", STALL_TIMEOUT.to_i)).seconds
  end

  def stallable?
    status.in?(ACTIVE_STATUSES)
  end

  def start!
    update!(status: "streaming", last_activity_at: Time.current)
  end

  def touch_activity!
    update!(last_activity_at: Time.current) unless terminal?
  end

  def complete!(awaiting_confirmation: false)
    update!(
      status: awaiting_confirmation ? "awaiting_confirmation" : "completed",
      completed_at: awaiting_confirmation ? nil : Time.current,
      last_activity_at: Time.current
    )
  end

  def fail!(classification:)
    update!(status: "failed", classification:, completed_at: Time.current, last_activity_at: Time.current)
  end

  def stall!(detected_at:, reason:)
    return false unless self.class.where(id:, status: ACTIVE_STATUSES).update_all(
      status: "stalled", classification: reason, stalled_at: detected_at, last_activity_at: detected_at, updated_at: detected_at
    ).positive?

    reload
    true
  end

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end
end
