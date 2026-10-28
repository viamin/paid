# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    initiating_message { association :chat_message, chat_session: chat_session, role: "user" }
    status { "streaming" }
    last_activity_at { Time.current }
    metadata { {} }
  end
end
