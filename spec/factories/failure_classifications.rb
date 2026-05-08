# frozen_string_literal: true

FactoryBot.define do
  factory :failure_classification do
    project
    agent_run
    failure_category { "provider_error" }
    chosen_action { "retry_alternate_provider" }
    action_status { "pending" }
    failure_context { {} }
    action_params { {} }
    action_result { {} }

    trait :timeout do
      failure_category { "timeout" }
      chosen_action { "retry_same_provider" }
    end

    trait :auth_failure do
      failure_category { "auth_failure" }
      chosen_action { "pause_and_notify" }
    end

    trait :rate_limit do
      failure_category { "rate_limit" }
      chosen_action { "retry_alternate_provider" }
    end

    trait :executing do
      action_status { "executing" }
      executed_at { Time.current }
    end

    trait :completed do
      action_status { "completed" }
      executed_at { 5.minutes.ago }
      completed_at { Time.current }
      action_result { { recovered: true } }
    end

    trait :skipped do
      action_status { "skipped" }
    end

    trait :with_workflow do
      parent_workflow_id { "workflow-#{SecureRandom.hex(4)}" }
    end
  end
end
