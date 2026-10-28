# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  include TenantScoped

  STATUSES = %w[pending streaming awaiting_confirmation rate_limited completed failed stalled abandoned].freeze
  EXECUTING_STATUSES = %w[pending streaming].freeze
  TERMINAL_STATUSES = %w[completed failed stalled abandoned].freeze

  belongs_to :chat_session
  belongs_to :initiated_by, class_name: "User"
  belongs_to :user_message, class_name: "ChatMessage", optional: true
  belongs_to :notice_message, class_name: "ChatMessage", optional: true
  belongs_to :recovery_requested_by, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :stream_id, uniqueness: { scope: :chat_session_id }

  scope :stall_candidates, ->(cutoff) {
    where(status: EXECUTING_STATUSES, last_activity_at: ..cutoff)
      .where("lease_expires_at IS NULL OR lease_expires_at <= ?", Time.current)
  }
  scope :stalled, -> { where(status: "stalled") }
  scope :recovered, -> { where.not(recovery_finished_at: nil) }
  scope :abandoned, -> { where(status: "abandoned") }

  # @spec CHAT-API-027 CHAT-API-032
  def record_activity!(message = nil)
    attributes = { last_activity_at: Time.current }
    attributes[:checkpoint] = checkpoint_for(message) if message
    attributes[:side_effecting_tools_completed] = true if completed_write_tool?(message)
    update!(attributes)
  end

  def complete!
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
  end

  def automatically_recoverable?
    failure_classification == "infrastructure_failure" && checkpoint_replay_safe? &&
      !side_effecting_tools_completed? && recovery_attempts.zero?
  end

  def append_audit_event!(event, **details)
    with_lock do
      self.audit_events = audit_events + [ details.stringify_keys.merge("event" => event, "at" => Time.current.iso8601) ]
      save!
    end
  end

  private

  def checkpoint_for(message)
    checkpoint.merge("last_message_id" => message.id, "last_message_role" => message.role)
  end

  def completed_write_tool?(message)
    message&.role == "tool" && message.tool_result.present? && Tools::Registry.write_tool?(message.tool_name)
  end
end
