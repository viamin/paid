# frozen_string_literal: true

FactoryBot.define do
  factory :collector_run do
    project_version
    collector_type { "ast_grep_routes" }
    status { "pending" }

    trait :running do
      status { "running" }
      started_at { Time.current }
    end

    trait :completed do
      status { "completed" }
      started_at { 10.seconds.ago }
      completed_at { Time.current }
      duration_ms { 10_000 }
    end

    trait :failed do
      status { "failed" }
      started_at { 10.seconds.ago }
      completed_at { Time.current }
      error_message { "Collector failed" }
    end
  end
end
