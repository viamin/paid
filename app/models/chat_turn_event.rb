# frozen_string_literal: true

class ChatTurnEvent < ApplicationRecord
  EVENT_TYPES = %w[created activity completed failed stalled recovery_requested recovery_duplicate].freeze

  belongs_to :chat_turn

  validates :event_type, inclusion: { in: EVENT_TYPES }
end
