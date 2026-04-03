# frozen_string_literal: true

FactoryBot.define do
  factory :collector_run do
    project_version
    sequence(:collector_type) { |n| "test_collector_#{n}" }
    status { "pending" }
    metadata { {} }

    trait :running do
      status { "running" }
      started_at { Time.current }
    end

    trait :completed do
      status { "completed" }
      started_at { 5.seconds.ago }
      completed_at { Time.current }
      duration_ms { 5000 }
      artifacts_count { 3 }
    end

    trait :failed do
      status { "failed" }
      started_at { 5.seconds.ago }
      completed_at { Time.current }
      error_message { "Something went wrong" }
    end

    trait :skipped do
      status { "skipped" }
      started_at { 5.seconds.ago }
      completed_at { Time.current }
      artifacts_count { 0 }
      error_message { "tool not available" }
    end
  end
end
