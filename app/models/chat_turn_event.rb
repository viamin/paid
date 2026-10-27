# frozen_string_literal: true

class ChatTurnEvent < ApplicationRecord
  EVENT_TYPES = %w[stall_detected recovery_requested recovery_started recovery_succeeded recovery_failed recovery_declined duplicate_prevented turn_abandoned].freeze

  belongs_to :chat_turn
  belongs_to :chat_session
  belongs_to :actor, class_name: "User", optional: true

  validates :event_type, inclusion: { in: EVENT_TYPES }
end
