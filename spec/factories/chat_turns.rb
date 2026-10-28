# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    stream_message_id { SecureRandom.uuid }
    status { "pending" }
    last_activity_at { Time.current }

    trait :streaming do
      status { "streaming" }
    end

    trait :awaiting_confirmation do
      status { "awaiting_confirmation" }
    end
  end
end
