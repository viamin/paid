# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  DEFAULT_STALL_THRESHOLD = 15.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, uniqueness: true, allow_nil: true

  scope :awaiting_outcome, -> { where(status: %w[pending streaming]) }
  scope :stale_before, ->(time) { awaiting_outcome.where(last_activity_at: ...time) }

  def self.stall_threshold
    seconds = Integer(ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", DEFAULT_STALL_THRESHOLD.to_i))
    seconds.positive? ? seconds.seconds : DEFAULT_STALL_THRESHOLD
  rescue ArgumentError
    DEFAULT_STALL_THRESHOLD
  end

  def pending_confirmation?
    chat_session.messages.pending_tool_confirmations.exists?
  end

  def mark_streaming!
    with_lock do
      return false unless status.in?(%w[pending streaming])

      update!(status: "streaming", last_activity_at: Time.current)
      true
    end
  end

  def record_activity!
    update!(last_activity_at: Time.current) if status.in?(%w[pending streaming])
  end

  def complete!
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current) if status.in?(%w[pending streaming])
  end

  def fail!(classification:)
    update!(status: "failed", failure_classification: classification, last_activity_at: Time.current) if status.in?(%w[pending streaming])
  end

  def side_effecting_tools_completed?
    completed_tool_calls = chat_session.messages.where(role: "assistant", tool_status: "approved").where.not(tool_call_id: nil).select(:tool_call_id)
    chat_session.messages.where(role: "tool", tool_call_id: completed_tool_calls).exists?
  end
end
