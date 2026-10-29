# frozen_string_literal: true

FactoryBot.define do
  factory :chat_turn do
    chat_session
    user_message { association :chat_message, chat_session: chat_session }
    status { "streaming" }
    started_at { 10.minutes.ago }
    last_activity_at { 10.minutes.ago }

    trait :stalled do
      status { "stalled" }
      stall_detected_at { 1.minute.ago }
    end

    trait :write_tool_dispatched do
      write_tool_dispatched { true }
    end
  end
end
