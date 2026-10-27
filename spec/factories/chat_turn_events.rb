# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn_event do
    chat_turn
    event_type { "started" }
    metadata { {} }
  end
end
