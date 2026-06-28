# frozen_string_literal: true

FactoryBot.define do
  factory :change_intent do
    project
    chat_session { association :chat_session, project:, account: project.account }
    issue { nil }
    title { "Prefer sliding window rate limiting" }
    intent { "Smooth request limiting for public API endpoints." }
    behavior { "Given bursty traffic, keep limits even across the rolling window." }
    constraints { "Use Redis and match the auth middleware layout." }
    decisions_made { "Rejected token bucket because it was harder to reason about for support." }
    status { "active" }

    trait :draft do
      status { "draft" }
    end

    trait :superseded do
      status { "superseded" }
      superseded_by { association :change_intent, project: project }
    end

    trait :reverted do
      status { "reverted" }
    end
  end
end
