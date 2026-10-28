# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    association :chat_session
    user_message { association :chat_message, chat_session: chat_session, role: "user" }
    status { "pending" }
    activity_at { Time.current }

    trait :streaming do
      status { "streaming" }
    end
  end
end
