# frozen_string_literal: true

# Audit trail for chat turn stalls and recovery attempts.
#
# Every classification, detection, recovery attempt, recovery outcome, user
# action, and duplicate-prevention event lands here, so stall rate, recovery
# success rate, abandoned-turn rate, and duplicate-prevention counts are
# queryable without scanning transcript rows.
class ChatTurnEvent < ApplicationRecord
  EVENT_TYPES = %w[
    detected
    recovery_attempted
    recovery_succeeded
    recovery_failed
    user_action
    duplicate_prevented
    abandoned
  ].freeze
  OUTCOMES = %w[succeeded failed blocked duplicate].freeze

  belongs_to :chat_turn
  belongs_to :chat_session
  belongs_to :actor, class_name: "User", optional: true

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true

  scope :detections, -> { where(event_type: "detected") }
  scope :duplicate_preventions, -> { where(event_type: "duplicate_prevented") }
  scope :recoveries, -> { where(event_type: %w[recovery_attempted recovery_succeeded recovery_failed]) }
end
