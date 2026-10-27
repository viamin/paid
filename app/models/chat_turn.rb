# frozen_string_literal: true

# Durable lifecycle record for one interactive chat turn: the work between a
# persisted user message and the terminal assistant response that answers it.
#
# A turn exists so that "did this exchange reach a conclusion?" is answerable
# from durable state instead of from the browser's transient streaming flags.
# See docs/intent/chat-turn-stall-recovery/.
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze
  TERMINAL_STATUSES = %w[completed failed stalled abandoned].freeze
  STALL_CLASSIFICATIONS = %w[
    infrastructure_failure
    provider_timeout
    budget_exhausted
    client_disconnect
    model_stop
  ].freeze
  RECOVERY_STATUSES = %w[none in_progress succeeded failed].freeze
  RECOVERY_ACTIONS = %w[resume retry].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true
  belongs_to :checkpoint_message, class_name: "ChatMessage", optional: true

  has_many :chat_turn_events, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :stall_classification, inclusion: { in: STALL_CLASSIFICATIONS }, allow_nil: true
  validates :recovery_status, inclusion: { in: RECOVERY_STATUSES }

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :stalled, -> { where(status: "stalled") }
  scope :abandonable, ->(cutoff) { stalled.where(stalled_at: ...cutoff) }

  class << self
    # The session's open turn: the newest turn that has not reached a terminal
    # outcome. A stalled turn stays open to recovery, so it is not active.
    #
    # A turn that is being recovered wins over any other open turn, so the
    # activity a recovery produces is recorded against the turn it recovers.
    def active_for(chat_session)
      recovering = where(chat_session_id: chat_session.id, recovery_status: "in_progress").order(id: :desc).first
      return recovering if recovering

      active.where(chat_session_id: chat_session.id).order(id: :desc).first
    end
  end

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def stalled?
    status == "stalled"
  end

  def completed?
    status == "completed"
  end

  def client_disconnected?
    metadata.is_a?(Hash) && metadata["client_disconnect"] == true
  end

  # Durable evidence about what the turn managed to do before it stopped.
  def evidence
    @evidence ||= Evidence.new(self)
  end

  # Applies a lifecycle change without the optimistic-locking exception: two
  # writers may legitimately touch the same turn (the loop recording activity
  # while a sweep classifies it), and losing that race must never break the
  # turn that is making progress.
  #
  # `guard` restricts the write to the rows still in the expected state, so a
  # late completion cannot overwrite a turn a sweep already classified.
  def apply_update!(attributes, guard: {})
    scope = self.class.where(id: id)
    scope = scope.where(guard) if guard.present?
    scope.update_all(
      attributes.merge(updated_at: Time.current, lock_version: Arel.sql("lock_version + 1"))
    )
    reload
    self
  end
end
