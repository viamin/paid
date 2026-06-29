# frozen_string_literal: true

FactoryBot.define do
  factory :change_intent do
    project
    chat_session { association :chat_session, :with_project, account: project.account, project: project }
    issue { association :issue, project: project }
    title { "Use sliding window rate limiting" }
    intent { "Smooth API rate limiting without surprising client bursts." }
    behavior { "Given repeated requests, when a client exceeds the window, then requests should be throttled predictably." }
    constraints { "Use Redis and follow the existing auth middleware pattern." }
    decisions_made { "Rejected token bucket because smoother limiting matters more than burst tolerance." }
    status { "active" }

    trait :draft do
      status { "draft" }
    end

    trait :superseded do
      status { "superseded" }
      superseded_by { association :change_intent, project: project }
    end

    trait :without_context_links do
      chat_session { nil }
      issue { nil }
    end
  end
end
