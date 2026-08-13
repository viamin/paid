# frozen_string_literal: true

FactoryBot.define do
  factory :workflow_state do
    temporal_workflow_id { "workflow-#{SecureRandom.uuid}" }
    workflow_type { "AgentExecutionWorkflow" }
    status { "running" }
    started_at { Time.current }

    trait :with_project do
      project
    end

    trait :with_run_id do
      temporal_run_id { "run-#{SecureRandom.uuid}" }
    end

    trait :completed do
      status { "completed" }
      completed_at { Time.current }
      result_data { { pr_url: "https://github.com/example/repo/pull/1" } }
    end

    trait :failed do
      status { "failed" }
      completed_at { Time.current }
      error_message { "Workflow execution failed" }
    end

    trait :cancelled do
      status { "cancelled" }
      completed_at { Time.current }
    end

    trait :timed_out do
      status { "timed_out" }
      completed_at { Time.current }
    end

    trait :with_input_data do
      input_data { { issue_id: 123, prompt: "Implement feature" } }
    end
  end
end
