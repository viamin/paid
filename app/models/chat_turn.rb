# frozen_string_literal: true

# Durable record of one interactive chat turn: the user message that opened it,
# the lifecycle state it reached, why it stopped, and what recovery was
# attempted. See `docs/intent/chat-turn-recovery/chat-turn-recovery-design.md`.
#
# @spec CHAT-TURN-RECOVERY-001
class ChatTurn < ApplicationRecord
  STATES = %w[pending streaming completed failed stalled abandoned].freeze
  OPEN_STATES = %w[pending streaming].freeze
  CLASSIFICATIONS = %w[
    pending_confirmation
    long_running_operation
    budget_exhausted
    rate_limited
    provider_timeout
    client_disconnect
    infrastructure_failure
    ambiguous_model_stop
    unexpected_error
  ].freeze
  RECOVERY_STATES = %w[idle requested running completed failed denied].freeze

  # A recovery claim older than this is treated as abandoned: the process that
  # held it died, so the turn must be recoverable again instead of staying
  # permanently "requested".
  RECOVERY_CLAIM_STALE_AFTER = 15.minutes

  # Bounded automatic recovery. A turn that needs more than this many
  # unattended resumes is handed to the user instead of retried again.
  MAX_AUTOMATIC_RECOVERY_ATTEMPTS = 2
  # Total recovery attempts (automatic plus user-requested) allowed per turn.
  MAX_RECOVERY_ATTEMPTS = 3

  # Platform floor for stall detection. A tenant may wait longer than this
  # (TenantSetting#chat_stall_threshold_seconds) but never less.
  DEFAULT_STALL_THRESHOLD = 10.minutes

  def self.stall_threshold
    seconds = ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", "").to_i
    seconds.positive? ? seconds.seconds : DEFAULT_STALL_THRESHOLD
  end

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"
  has_many :events, class_name: "ChatTurnEvent", dependent: :destroy

  validates :state, inclusion: { in: STATES }
  validates :classification, inclusion: { in: CLASSIFICATIONS }, allow_nil: true
  validates :recovery_state, inclusion: { in: RECOVERY_STATES }
  validates :user_message_id, uniqueness: true

  scope :open, -> { where(state: OPEN_STATES) }
  scope :stalled, -> { where(state: "stalled") }
  scope :abandoned, -> { where(state: "abandoned") }
  scope :recoverable, -> { where(state: %w[stalled abandoned]) }
  scope :without_terminal_outcome, -> { where(state: OPEN_STATES) }
  # A turn can be claimed for recovery when no recovery is in flight, or when
  # the previous claim went stale (the process holding it died).
  scope :recovery_claimable, ->(now = Time.current) {
    stale_before = now - RECOVERY_CLAIM_STALE_AFTER
    where(recovery_state: "idle")
      .or(where(recovery_state: %w[requested running])
        .where("recovery_requested_at IS NULL OR recovery_requested_at < ?", stale_before))
  }

  def open?
    state.in?(OPEN_STATES)
  end

  # How long the turn may stay silent before it is a stall candidate.
  def stall_threshold
    tenant_threshold = chat_session.account.tenant_setting&.chat_stall_threshold_seconds.to_i
    [ self.class.stall_threshold, tenant_threshold.seconds ].max
  end

  def terminal?
    state.in?(%w[completed failed])
  end

  def recoverable?
    state.in?(%w[stalled abandoned])
  end

  # @spec CHAT-TURN-RECOVERY-004
  def record_activity!(at: Time.current)
    return false unless open?

    update!(last_activity_at: at, state: "streaming", revision: revision + 1)
    true
  end

  # @spec CHAT-TURN-RECOVERY-002
  def complete!(at: Time.current)
    update!(state: "completed", completed_at: at, revision: revision + 1)
  end

  # @spec CHAT-TURN-RECOVERY-003
  def fail!(classification:, at: Time.current)
    update!(state: "failed", classification:, completed_at: at, revision: revision + 1)
  end

  # @spec CHAT-TURN-RECOVERY-004
  # The compare-and-swap keeps a second detector pass (or a manual recovery
  # racing the detector) from re-classifying a turn that already reached a
  # terminal state.
  def mark_stalled!(classification:, at: Time.current)
    transition_open_turn!(state: "stalled", classification:, at:)
  end

  # @spec CHAT-TURN-RECOVERY-004
  def mark_abandoned!(classification:, at: Time.current)
    transition_open_turn!(state: "abandoned", classification:, at:)
  end

  # @spec CHAT-TURN-RECOVERY-003
  def mark_failed!(classification:, at: Time.current)
    transition_open_turn!(state: "failed", classification:, at:)
  end

  def transition_open_turn!(state:, classification:, at: Time.current)
    rows = self.class.where(id: id, state: OPEN_STATES).update_all(
      state: state,
      classification: classification,
      completed_at: (at if state == "failed"),
      detected_at: (at if %w[stalled abandoned].include?(state)),
      revision: revision + 1,
      updated_at: at
    )
    return false if rows.zero?

    reload
    true
  end

  # Re-opens a stalled or abandoned turn for recovery. The revision bump makes
  # any notice rendered before the recovery stale.
  def reopen!(at: Time.current)
    update!(
      state: "streaming",
      classification: nil,
      detected_at: nil,
      last_activity_at: at,
      revision: revision + 1
    )
  end

  def mark_client_disconnected!(at: Time.current)
    return if client_disconnected_at.present?

    update!(client_disconnected_at: at, revision: revision + 1)
  end

  # @spec CHAT-TURN-RECOVERY-011
  # Atomically claims the single recovery slot for this turn. The compare-and-
  # swap on `recovery_state` is what deduplicates concurrent recovery requests:
  # only one caller can move the row out of a claimable state, and every other
  # caller observes zero updated rows.
  def claim_recovery!(now: Time.current)
    rows = self.class.where(id: id).recovery_claimable(now).update_all(
      recovery_state: "requested",
      recovery_requested_at: now,
      recovery_attempts: recovery_attempts + 1,
      revision: revision + 1,
      updated_at: now
    )
    return false if rows.zero?

    reload
    true
  end

  def finish_recovery!(outcome:, at: Time.current)
    update!(
      recovery_state: outcome,
      recovery_completed_at: at,
      revision: revision + 1
    )
  end

  # A turn is replay-safe only when nothing that changed the outside world
  # completed inside it. Read-only tool calls may be replayed; write tools may
  # not.
  # @spec CHAT-TURN-RECOVERY-008
  def replay_safe?
    !side_effecting_tools_completed
  end

  # @spec CHAT-TURN-RECOVERY-008
  def automatic_recovery_eligible?
    replay_safe? &&
      recovery_attempts < MAX_AUTOMATIC_RECOVERY_ATTEMPTS &&
      classification == "infrastructure_failure"
  end

  def recovery_attempts_exhausted?
    recovery_attempts >= MAX_RECOVERY_ATTEMPTS
  end

  def record_event(event_type:, outcome: nil, actor: nil, metadata: {})
    events.create!(
      event_type: event_type,
      outcome: outcome,
      actor_id: actor&.id,
      metadata: metadata
    )
  end
end
