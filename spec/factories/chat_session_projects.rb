# frozen_string_literal: true

FactoryBot.define do
  factory :chat_session_project do
    chat_session
    project { association :project, account: chat_session.account }
    context_type { "reference" }

    trait :primary do
      context_type { "primary" }
    end
  end
end
