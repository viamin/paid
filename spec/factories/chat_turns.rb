# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    user_message { create(:chat_message, chat_session:) }
    status { "streaming" }
    stream_message_id { SecureRandom.uuid }
    last_activity_at { Time.current }
  end
end
