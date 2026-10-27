# frozen_string_literal: true

class ChatTurnEvent < ApplicationRecord
  belongs_to :chat_turn
  belongs_to :actor, class_name: "User", optional: true

  validates :event_type, presence: true
end
