# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    actor { chat_session.created_by }
    status { "pending" }
    last_activity_at { Time.current }
  end
end
