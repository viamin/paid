# frozen_string_literal: true

# Durable lifecycle record for one chat turn (#4680): the span from a
# persisted user ChatMessage to a terminal outcome. Exists so a crashed
# worker, a hung provider call, or a dropped connection leaves a detectable,
# auditable trail instead of a silent stop — see
# docs/intent/chat-turn-stall-recovery/.
class ChatTurn < ApplicationRecord
  class RecoveryRequiredError < StandardError; end

  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze
  FAILURE_CLASSIFICATIONS = %w[rate_limited provider_error budget_exhausted validation_error unsupported_configuration unexpected_error].freeze
  AUTOMATIC_RECOVERY_CLASSIFICATIONS = %w[infrastructure_failure].freeze

  # Automatic (unconfirmed) recovery is only attempted for a turn that never
  # touched a write tool — see ChatTurn#eligible_for_automatic_recovery?. This
  # is the initial, conservative replay-safety contract: no tool currently
  # opts in to broader automatic replay.
  MAX_AUTOMATIC_RECOVERY_ATTEMPTS = 1
  MAX_RECOVERY_ATTEMPTS = 3

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"
  has_many :lifecycle_events, class_name: "ChatTurnLifecycleEvent", dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :failure_classification, inclusion: { in: FAILURE_CLASSIFICATIONS }, allow_nil: true

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :stale, ->(before:) { active.where(last_activity_at: ...before) }

  def self.start!(chat_session:, user_message:)
    turn = find_by(user_message_id: user_message.id)
    return turn if turn

    create!(
      chat_session: chat_session,
      user_message: user_message,
      status: "pending",
      started_at: Time.current,
      last_activity_at: Time.current
    )
  end

  def record_activity!(message)
    updates = { last_activity_at: Time.current }
    updates[:status] = "streaming" if status == "pending"
    updates[:write_tool_dispatched] = true if !write_tool_dispatched && write_tool_message?(message)
    update!(updates)
  end

  def complete!(assistant_message)
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
    ChatTurns::Lifecycle.record(
      event_name: "chat_turn.completed",
      chat_turn: self,
      metadata: { assistant_message_id: assistant_message&.id }
    )
  end

  def fail!(error:)
    update!(
      status: "failed",
      failure_classification: classify_failure(error),
      completed_at: Time.current,
      last_activity_at: Time.current
    )
    ChatTurns::Lifecycle.record(
      event_name: "chat_turn.failed",
      chat_turn: self,
      metadata: { error_class: error.class.name }
    )
  end

  def mark_stalled!
    update!(status: "stalled", stall_detected_at: Time.current)
    ChatTurns::Lifecycle.record(
      event_name: "chat_turn.stall_detected",
      chat_turn: self,
      metadata: { write_tool_dispatched: write_tool_dispatched, last_activity_at: last_activity_at.iso8601 }
    )
  end

  def abandon!
    update!(status: "abandoned", completed_at: Time.current)
    ChatTurns::Lifecycle.record(event_name: "chat_turn.abandoned", chat_turn: self)
  end

  # Atomically transitions this turn from `stalled` to `streaming`, so a
  # concurrent sweep tick and a concurrent manual Resume click cannot both
  # start recovery for the same turn (#4680 AC6). Only the caller whose
  # UPDATE actually matches the `stalled` WHERE clause wins the race; the
  # loser's statement matches zero rows. Mirrors
  # ChatSessions::ResolveToolCall#claim_resolution!.
  def claim_recovery!(triggered_by:, actor: nil)
    return reject_recovery!(triggered_by:, actor:) if abandon_if_recovery_exhausted!

    rows = self.class.where(id: id, status: "stalled").update_all(
      status: "streaming",
      recovery_locked_at: Time.current,
      recovery_attempts: recovery_attempts + 1,
      last_activity_at: Time.current
    )
    reload
    return reject_recovery!(triggered_by:, actor:) unless rows.positive?

    ChatTurns::Lifecycle.record(
      event_name: "chat_turn.recovery_attempted",
      chat_turn: self,
      actor: actor,
      metadata: { triggered_by: triggered_by, recovery_attempts: recovery_attempts }
    )
    true
  end

  def eligible_for_automatic_recovery?
    status == "stalled" &&
      infrastructure_failure? &&
      !write_tool_dispatched &&
      recovery_attempts < MAX_AUTOMATIC_RECOVERY_ATTEMPTS
  end

  def recovery_exhausted?
    recovery_attempts >= MAX_RECOVERY_ATTEMPTS
  end

  def awaiting_confirmation?
    chat_session.messages.pending_tool_confirmations.exists?
  end

  def expected_long_running?
    expected_long_running_until&.future?
  end

  private

  def infrastructure_failure?
    metadata.fetch("recovery_classification", nil).in?(AUTOMATIC_RECOVERY_CLASSIFICATIONS)
  end

  def expected_long_running_until
    value = metadata["expected_long_running_until"]
    Time.zone.parse(value) if value.present?
  rescue ArgumentError, TypeError
    nil
  end

  def abandon_if_recovery_exhausted!
    rows = self.class.where(id: id, status: "stalled")
      .where("recovery_attempts >= ?", MAX_RECOVERY_ATTEMPTS)
      .update_all(status: "abandoned", completed_at: Time.current)
    return false unless rows.positive?

    reload
    ChatTurns::Lifecycle.record(event_name: "chat_turn.abandoned", chat_turn: self)
    true
  end

  def reject_recovery!(triggered_by:, actor:)
    ChatTurns::Lifecycle.record(
      event_name: "chat_turn.recovery_duplicate_prevented",
      chat_turn: self,
      actor: actor,
      metadata: { triggered_by: triggered_by, status: status, recovery_attempts: recovery_attempts }
    )
    false
  end

  def write_tool_message?(message)
    message.role == "assistant" && message.tool_name.present? && Tools::Registry.write_tool?(message.tool_name)
  end

  def classify_failure(error)
    case error
    when AgentHarness::RateLimitError then "rate_limited"
    when AgentHarness::Error then "provider_error"
    when ChatSessions::TokenLimitExceededError then "budget_exhausted"
    when ArgumentError then "validation_error"
    when NotImplementedError then "unsupported_configuration"
    else "unexpected_error"
    end
  end
end
