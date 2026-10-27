# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    user_message { association(:chat_message, chat_session:) }
    actor { chat_session.created_by }
    status { "streaming" }
    stream_message_id { SecureRandom.uuid }
    last_activity_at { Time.current }
    metadata { {} }

    trait :streaming do
      status { "streaming" }
    end

    trait :awaiting_confirmation do
      status { "awaiting_confirmation" }
    end
  end
end
