# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    state { "pending" }
    last_activity_at { Time.current }

    trait :streaming do
      state { "streaming" }
    end
  end
end
