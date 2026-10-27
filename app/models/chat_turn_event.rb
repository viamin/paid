# frozen_string_literal: true

class ChatTurnEvent < ApplicationRecord
  belongs_to :chat_turn

  validates :event_type, presence: true
end
