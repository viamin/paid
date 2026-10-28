# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    stream_message_id { SecureRandom.uuid }
    state { "pending" }
    checkpointed_at { Time.current }

    trait :streaming do
      state { "streaming" }
    end
  end
end
