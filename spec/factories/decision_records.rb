# frozen_string_literal: true

FactoryBot.define do
  factory :decision_record do
    project
    agent_run { association :agent_run, :completed, project: project }
    issue { agent_run&.issue }
    title { "Use JWT for API authentication" }
    summary { "Decided to use JWT tokens for API authentication instead of session-based auth." }
    context { "The existing session-based auth doesn't work well for API clients." }
    decision { "Implement JWT-based authentication for all API endpoints." }
    consequences { "API clients will need to manage token refresh. Session-based auth remains for web UI." }
    status { "active" }
    commit_sha_start { "0123456789abcdef0123456789abcdef01234567" }
    commit_sha_end { "abcdef0123456789abcdef0123456789abcdef01" }
    tags { %w[auth api] }

    trait :draft do
      status { "draft" }
    end

    trait :superseded do
      status { "superseded" }
      superseded_by { association :decision_record, project: project }
    end

    trait :reverted do
      status { "reverted" }
    end

    trait :without_agent_run do
      agent_run { nil }
      issue { nil }
    end
  end
end
