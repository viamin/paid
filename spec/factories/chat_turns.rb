# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    user_message { association(:chat_message, chat_session:) }
    status { "streaming" }
    last_activity_at { Time.current }

    trait :stalled do
      status { "stalled" }
      detected_at { Time.current }
    end
  end
end
