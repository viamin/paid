# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    association :chat_session
    user_message { association(:chat_message, :user, chat_session: chat_session) }
    state { "streaming" }
    last_activity_at { Time.current }
  end
end
