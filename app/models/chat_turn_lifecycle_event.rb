# frozen_string_literal: true

# Append-only audit trail for ChatTurn stall classification, recovery
# attempts, outcomes, and duplicate-prevention events (#4680). Rows are
# never updated after insert — write through ChatTurns::Lifecycle rather than
# calling .create! directly, so a logging failure never aborts the caller's
# real work.
class ChatTurnLifecycleEvent < ApplicationRecord
  EVENT_NAME_PATTERN = /\A[a-z0-9_]+(\.[a-z0-9_]+)+\z/

  belongs_to :chat_turn
  belongs_to :chat_session
  belongs_to :actor, class_name: "User", optional: true

  validates :event_name, presence: true, format: { with: EVENT_NAME_PATTERN }
  validates :occurred_at, presence: true

  scope :for_chat_turn, ->(chat_turn) { where(chat_turn: chat_turn) }
  scope :by_event_name, ->(event_name) { where(event_name: event_name) }
  scope :recent, -> { order(occurred_at: :desc, id: :desc) }

  def readonly?
    persisted?
  end
end
