# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  # @spec CHAT-API-025 CHAT-API-027
  STATUSES = %w[streaming completed failed stalled abandoned pending_confirmation].freeze
  RECOVERABLE_STATUSES = %w[stalled failed].freeze
  KNOWN_OPERATION_LEASE = 30.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :recovery_requested_by, class_name: "User", optional: true
  has_many :messages, class_name: "ChatMessage", dependent: :nullify
  has_many :events, class_name: "ChatTurnEvent", dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :user_message_id, uniqueness: true

  scope :stale_streaming, ->(before) { where(status: "streaming").where(last_activity_at: ...before) }

  def self.stall_threshold
    Integer(ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", 10.minutes.to_i)).seconds
  rescue ArgumentError
    10.minutes
  end

  def terminal?
    status.in?(%w[completed failed abandoned stalled])
  end

  def touch_activity!(checkpoint: nil)
    attributes = { last_activity_at: Time.current }
    attributes[:checkpoint] = checkpoint if checkpoint
    update!(attributes)
  end

  def begin_operation!(tool_name:)
    update!(last_activity_at: Time.current, checkpoint: checkpoint.merge(
      "active_tool_name" => tool_name,
      "operation_lease_until" => KNOWN_OPERATION_LEASE.from_now.iso8601
    ))
  end

  def finish_operation!
    update!(last_activity_at: Time.current, checkpoint: checkpoint.except("active_tool_name", "operation_lease_until"))
  end

  def operation_lease_active?(now = Time.current)
    Time.iso8601(checkpoint.fetch("operation_lease_until")) > now
  rescue KeyError, ArgumentError
    false
  end

  def complete!(outcome: "completed")
    update!(status: "completed", completed_at: Time.current, recovery_outcome: outcome, last_activity_at: Time.current)
    record_event!("completed", outcome: outcome)
    record_event!("recovery_succeeded") if recovery_attempts.positive?
  end

  def fail!(classification:)
    update!(status: "failed", failure_classification: classification, last_activity_at: Time.current)
    record_event!("failed", classification: classification)
    record_event!("recovery_failed", classification: classification) if recovery_attempts.positive?
  end

  def await_confirmation!
    update!(status: "pending_confirmation", last_activity_at: Time.current)
    record_event!("pending_confirmation")
  end

  def claim_recovery!(actor:, expected_lock_version:)
    with_lock do
      reload
      unless status == "stalled" && lock_version == expected_lock_version
        record_event!("recovery_duplicate_prevented", actor: actor, expected_lock_version: expected_lock_version)
        return false
      end

      update!(status: "streaming", recovery_attempts: recovery_attempts + 1,
        recovery_requested_by: actor, recovery_outcome: nil, last_activity_at: Time.current)
      record_event!("recovery_requested", actor: actor, expected_lock_version: expected_lock_version)
      true
    end
  end

  def side_effecting_tools_completed?
    tool_call_ids = messages.where(role: "tool").where.not(tool_call_id: nil).select(:tool_call_id)
    chat_session.messages.where(tool_call_id: tool_call_ids, tool_status: "approved").exists?
  end

  def record_event!(event_type, actor: nil, **metadata)
    events.create!(event_type: event_type, actor: actor, metadata: metadata)
  end
end
