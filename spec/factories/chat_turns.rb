# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    content { "Hello" }
    started_at { 20.minutes.ago }
    last_activity_at { started_at }

    trait :streaming do
      status { "streaming" }
    end

    trait :awaiting_confirmation do
      status { "awaiting_confirmation" }
    end
  end
end
