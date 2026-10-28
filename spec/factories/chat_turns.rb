# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    status { "pending" }
    last_activity_at { Time.current }

    trait :streaming do
      status { "streaming" }
    end

    trait :completed do
      status { "completed" }
      completed_at { Time.current }
    end
  end
end
