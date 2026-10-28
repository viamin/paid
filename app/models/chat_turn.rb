# frozen_string_literal: true

# Durable server-side lifecycle for one chat execution attempt. A transcript is
# authoritative evidence; a turn records whether that evidence reached a
# terminal conclusion.
class ChatTurn < ApplicationRecord
  # @spec CHAT-TURN-001 CHAT-TURN-002
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze
  STALL_THRESHOLD = ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", 10.minutes).to_i.seconds

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"
  belongs_to :actor, class_name: "User"

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, uniqueness: true, allow_nil: true

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :stale, ->(now = Time.current) { active.where(last_activity_at: ..(now - STALL_THRESHOLD)) }

  def start!
    update!(status: "streaming", last_activity_at: Time.current)
  end

  def record_activity!(message: nil)
    attributes = { last_activity_at: Time.current }
    attributes[:side_effecting_tool_completed] = true if completed_side_effecting_tool?(message)
    update!(attributes)
  end

  def complete!(outcome: "completed")
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current,
      metadata: metadata.merge("outcome" => outcome))
  end

  def fail!(classification:)
    update!(status: "failed", completed_at: Time.current, last_activity_at: Time.current,
      failure_classification: classification)
  end

  def stall!
    with_lock do
      reload
      return false unless status.in?(ACTIVE_STATUSES) && last_activity_at <= Time.current - STALL_THRESHOLD
      return false if pending_confirmation?

      update!(status: "stalled", stalled_at: Time.current, failure_classification: "inactivity")
      true
    end
  end

  def retryable?
    !side_effecting_tool_completed? && !tool_activity?
  end

  def claim_retry!
    with_lock do
      reload
      return false unless status.in?(%w[stalled failed]) && retryable?

      update!(status: "streaming", recovery_attempts: recovery_attempts + 1,
        last_activity_at: Time.current, metadata: metadata.merge("recovery_requested_at" => Time.current.iso8601))
      true
    end
  end

  def pending_confirmation?
    chat_session.messages.pending_tool_confirmations.where("id >= ?", user_message_id).exists?
  end

  def tool_activity?
    chat_session.messages.where("id >= ?", user_message_id).where("tool_name IS NOT NULL OR role = 'tool'").exists?
  end

  private

  def completed_side_effecting_tool?(message)
    message&.role == "tool" && message.tool_name.present? &&
      chat_session.messages.where(tool_call_id: message.tool_call_id, tool_status: "approved").exists?
  end
end
