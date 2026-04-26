# frozen_string_literal: true

FactoryBot.define do
  factory :chat_message do
    chat_session
    role { "user" }
    content { "Hello, how can you help me?" }

    trait :assistant do
      role { "assistant" }
      content { "I can help you with your project." }
      model { "claude-sonnet-4-20250514" }
    end

    trait :system do
      role { "system" }
      content { "You are a helpful assistant." }
    end

    trait :tool do
      role { "tool" }
      content { nil }
      tool_call_id { "call_123" }
      tool_name { "search" }
      tool_result { { results: [] } }
    end
  end
end
