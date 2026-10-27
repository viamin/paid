# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    status { "streaming" }
    last_activity_at { Time.current }
    metadata { {} }
  end
end
