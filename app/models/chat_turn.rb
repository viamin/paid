# frozen_string_literal: true

# Durable lifecycle record for one user-initiated chat exchange. It is kept
# separate from the transcript so a missing terminal assistant row is visible.
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming awaiting_confirmation completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze
  DEFAULT_STALL_AFTER = 10.minutes

  belongs_to :chat_session
  belongs_to :initiating_message, class_name: "ChatMessage"
  belongs_to :terminal_message, class_name: "ChatMessage", optional: true

  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :stale_before, ->(time) { active.where(last_activity_at: ...time) }

  def self.stall_after
    seconds = Integer(ENV.fetch("CHAT_TURN_STALL_AFTER_SECONDS", DEFAULT_STALL_AFTER.to_i))
    seconds.positive? ? seconds.seconds : DEFAULT_STALL_AFTER
  rescue ArgumentError
    DEFAULT_STALL_AFTER
  end

  def touch_activity!
    update!(last_activity_at: Time.current) if persisted? && status.in?(ACTIVE_STATUSES)
  end

  def start!
    update!(status: "streaming", last_activity_at: Time.current)
  end

  def complete!(message)
    update!(status: "completed", terminal_message: message, last_activity_at: Time.current)
  end

  def await_confirmation!
    update!(status: "awaiting_confirmation", last_activity_at: Time.current)
  end

  def fail!(classification)
    update!(status: "failed", failure_classification: classification, last_activity_at: Time.current)
  end
end
