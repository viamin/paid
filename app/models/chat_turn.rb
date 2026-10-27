# frozen_string_literal: true

# Durable record for one user-initiated chat turn.
#
# A turn is the unit that can stall: it owns the persisted user message, the
# assistant/tool artifacts the agent loop produced, and the conclusion
# (completed, failed, stalled, abandoned) that the server reached. See
# `docs/intent/chat-turn-lifecycle/` for the lifecycle and the recovery
# contract.
#
# @spec CHAT-TURN-LIFECYCLE-001 @spec CHAT-TURN-LIFECYCLE-002
class ChatTurn < ApplicationRecord
  include TenantScoped

  STATUSES = %w[
    pending
    streaming
    awaiting_confirmation
    completed
    failed
    stalled
    abandoned
  ].freeze
  OPEN_STATUSES = %w[pending streaming awaiting_confirmation stalled].freeze
  TERMINAL_STATUSES = %w[completed failed abandoned].freeze

  # @spec CHAT-TURN-LIFECYCLE-003
  CLASSIFICATIONS = %w[
    pending_confirmation
    long_running_operation
    budget_exhausted
    provider_rate_limited
    client_disconnect
    model_stop
    infrastructure_failure
  ].freeze
  # Classifications whose recovery may be performed without an explicit human
  # confirmation. Opt-in per classification, never a blanket retry policy.
  # @spec CHAT-TURN-LIFECYCLE-006
  AUTO_RECOVERABLE_CLASSIFICATIONS = %w[infrastructure_failure].freeze
  # Classifications whose stop is ambiguous: the system cannot tell whether the
  # work already happened, so a human has to confirm the recovery.
  # @spec CHAT-TURN-LIFECYCLE-007
  CONFIRMATION_REQUIRED_CLASSIFICATIONS = %w[model_stop client_disconnect].freeze

  RECOVERY_STATES = %w[
    none
    awaiting_confirmation
    pending
    in_progress
    succeeded
    failed
    declined
  ].freeze
  CLAIMABLE_RECOVERY_STATES = %w[none awaiting_confirmation failed].freeze

  MAX_RECOVERY_ATTEMPTS = 2
  # Upper bound used to pre-filter stall candidates in SQL. The effective
  # per-account threshold is applied in Ruby so a longer configured threshold
  # is still honoured.
  MAX_STALL_THRESHOLD = 1.hour

  belongs_to :chat_session
  belongs_to :account
  belongs_to :user_message, class_name: "ChatMessage", optional: true
  belongs_to :assistant_message, class_name: "ChatMessage", optional: true
  belongs_to :checkpoint_message, class_name: "ChatMessage", optional: true
  has_many :chat_messages, dependent: :nullify
  has_many :events, class_name: "ChatTurnEvent", dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :recovery_state, inclusion: { in: RECOVERY_STATES }
  validates :classification, inclusion: { in: CLASSIFICATIONS }, allow_nil: true
  validates :recovery_attempts, numericality: { greater_than_or_equal_to: 0 }

  scope :open, -> { where(status: OPEN_STATUSES) }
  scope :running, -> { where(status: %w[pending streaming]) }
  scope :stalled, -> { where(status: "stalled") }
  scope :abandoned, -> { where(status: "abandoned") }
  scope :detected_stalls, -> { where.not(detected_at: nil) }

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def stalled?
    status == "stalled"
  end

  # @spec CHAT-TURN-LIFECYCLE-001
  # Advances the durable activity clock. Only ever moves forward, so an
  # out-of-order write cannot make a live turn look stale.
  def record_activity!(at: Time.current)
    return if last_activity_at.present? && last_activity_at >= at

    update_column(:last_activity_at, at)
  end

  def record_message!(message)
    update!(checkpoint_message_id: message.id, last_activity_at: message.created_at || Time.current)
  end

  def mark_streaming!
    return if terminal?

    update!(status: "streaming")
  end

  # @spec CHAT-TURN-LIFECYCLE-002
  def mark_completed!(assistant_message = nil)
    return if terminal?

    update!(
      status: "completed",
      completed_at: Time.current,
      assistant_message_id: assistant_message&.id,
      checkpoint_message_id: assistant_message&.id || checkpoint_message_id,
      last_activity_at: Time.current
    )
  end

  # @spec CHAT-TURN-LIFECYCLE-002
  def mark_failed!(classification: nil)
    return if terminal?

    update!(
      status: "failed",
      classification: classification,
      completed_at: Time.current,
      last_activity_at: Time.current
    )
  end

  # @spec CHAT-TURN-LIFECYCLE-003
  def mark_stalled!(classification:, detected_at: Time.current)
    update!(
      status: "stalled",
      classification: classification,
      detected_at: detected_at,
      stalled_at: detected_at,
      last_activity_at: last_activity_at || detected_at
    )
  end

  # @spec CHAT-TURN-LIFECYCLE-007
  def mark_abandoned!(user_action: "declined")
    update!(status: "abandoned", completed_at: Time.current, recovery_state: "declined")
  end

  # @spec CHAT-TURN-LIFECYCLE-006
  def auto_recoverable_classification?
    AUTO_RECOVERABLE_CLASSIFICATIONS.include?(classification.to_s)
  end

  # @spec CHAT-TURN-LIFECYCLE-007
  def confirmation_required_classification?
    CONFIRMATION_REQUIRED_CLASSIFICATIONS.include?(classification.to_s)
  end

  def recovery_budget_exhausted?
    recovery_attempts >= self.class::MAX_RECOVERY_ATTEMPTS
  end

  # @spec CHAT-TURN-LIFECYCLE-009
  # Compare-and-swap claim. Only one caller can move a turn out of a claimable
  # recovery state, so concurrent or repeated recovery requests cannot both
  # start a recovery.
  def claim_recovery!(to:, expected_states: CLAIMABLE_RECOVERY_STATES)
    rows = self.class
      .where(id: id, recovery_state: expected_states)
      .update_all(recovery_state: to, updated_at: Time.current)

    reload
    rows.positive?
  end

  def messages_chronological
    chat_messages.chronological
  end
end
