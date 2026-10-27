# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    account { chat_session.account }
    initiating_message { association :chat_message, chat_session: chat_session }
    status { "streaming" }
    activity_at { Time.current }
  end
end
