# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    account { chat_session.account }
    initiated_by { chat_session.created_by }
    stream_message_id { SecureRandom.uuid }
    status { "streaming" }
    last_activity_at { Time.current }
  end
end
