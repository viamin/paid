# frozen_string_literal: true

# Append-only audit trail for a chat turn: how it was classified, which
# recovery attempts ran, what the user did, and which duplicate recovery
# requests were prevented.
#
# @spec CHAT-TURN-RECOVERY-013
class ChatTurnEvent < ApplicationRecord
  EVENT_TYPES = %w[
    classified
    recovery_requested
    recovery_started
    recovery_completed
    recovery_failed
    duplicate_prevented
    user_action
  ].freeze

  belongs_to :chat_turn
  belongs_to :actor, class_name: "User", optional: true

  validates :event_type, inclusion: { in: EVENT_TYPES }

  scope :classified, -> { where(event_type: "classified") }
  scope :duplicate_prevented, -> { where(event_type: "duplicate_prevented") }
  scope :recovery, -> { where(event_type: %w[recovery_requested recovery_started recovery_completed recovery_failed]) }
end
