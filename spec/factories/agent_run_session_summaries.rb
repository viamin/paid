# frozen_string_literal: true

FactoryBot.define do
  factory :agent_run_session_summary do
    project { agent_run.project }
    agent_run { association :agent_run, :completed }
    issue { agent_run.issue }
    status { "observation" }
    summary { "Implemented rate limiting for the public API and added coverage for burst traffic." }
    files_touched { [ "app/services/rate_limiter.rb", "spec/services/rate_limiter_spec.rb" ] }
    decisions { [ "Chose a sliding window over a token bucket for smoother limiting." ] }
    assumptions { [ "Assumed Redis is available in every deployment environment." ] }
    failures { [] }
    follow_ups { [ "Add a dashboard panel for rate-limit rejections." ] }
    learnings { [ "Rate limit config lives in config/rate_limits.yml." ] }
    pull_request_number { agent_run.pull_request_number }
    pull_request_url { agent_run.pull_request_url }
    generated_at { Time.current }

    trait :promoted do
      status { "promoted" }
      promoted_at { Time.current }
      promoted_by { association :user }
      change_intent { association :change_intent, project: project }
    end
  end
end
