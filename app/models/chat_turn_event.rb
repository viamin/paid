# frozen_string_literal: true

# Append-only audit trail for chat turn lifecycle events.
#
# Every stall classification, recovery attempt, recovery outcome, user action,
# and duplicate-prevention decision lands here, so stall rate, recovery
# success rate, abandoned-turn rate, and duplicate prevention are queryable
# without replaying application logs.
#
# @spec CHAT-TURN-LIFECYCLE-011
class ChatTurnEvent < ApplicationRecord
  include TenantScoped

  EVENT_TYPES = %w[
    turn_started
    stall_detected
    notice_posted
    recovery_requested
    recovery_scheduled
    recovery_started
    recovery_succeeded
    recovery_failed
    recovery_declined
    duplicate_recovery_prevented
    client_disconnected
    turn_abandoned
  ].freeze
  USER_ACTIONS = %w[resume retry confirm abandon].freeze

  belongs_to :chat_turn
  belongs_to :chat_session
  belongs_to :account

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :user_action, inclusion: { in: USER_ACTIONS }, allow_nil: true

  scope :of_type, ->(type) { where(event_type: type) }
  scope :stalls, -> { of_type("stall_detected") }
  scope :recoveries, -> { where(event_type: %w[recovery_succeeded recovery_failed]) }
  scope :duplicates, -> { of_type("duplicate_recovery_prevented") }
  scope :recent, -> { order(created_at: :desc) }
end
