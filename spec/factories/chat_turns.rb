# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    account { chat_session.account }
    user_message { association :chat_message, chat_session: chat_session, role: "user" }
    stream_id { SecureRandom.uuid }
    status { "streaming" }
    last_activity_at { Time.current }
  end
end
