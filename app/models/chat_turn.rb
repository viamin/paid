# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming awaiting_confirmation completed failed stalled abandoned].freeze
  DEFAULT_STALL_THRESHOLD = 10.minutes

  belongs_to :chat_session

  validates :status, inclusion: { in: STATUSES }
  validates :external_id, uniqueness: true
  validates :content, presence: true

  scope :incomplete, -> { where(status: %w[pending streaming]) }
  scope :due_for_stall_detection, ->(cutoff) { incomplete.where(last_activity_at: ..cutoff) }

  def terminal?
    %w[awaiting_confirmation completed failed stalled abandoned].include?(status)
  end

  # @spec CHAT-TURN-STALL-001
  def mark_streaming!
    update!(status: "streaming", last_activity_at: Time.current)
  end

  def record_activity!
    return if terminal?

    touch(:last_activity_at)
  end

  def complete!(awaiting_confirmation: false)
    update!(
      status: awaiting_confirmation ? "awaiting_confirmation" : "completed",
      completed_at: Time.current,
      last_activity_at: Time.current
    )
  end

  def fail!
    update!(status: "failed", completed_at: Time.current, last_activity_at: Time.current)
  end

  # @spec CHAT-TURN-STALL-001
  def stall!(classification: "no_durable_activity")
    update!(
      status: "stalled",
      stalled_at: Time.current,
      last_activity_at: Time.current,
      stall_classification: classification
    )
  end

  def self.stall_threshold
    ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", DEFAULT_STALL_THRESHOLD.to_i).to_i.seconds
  end
end
