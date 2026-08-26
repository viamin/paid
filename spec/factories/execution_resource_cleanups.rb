# frozen_string_literal: true

FactoryBot.define do
  factory :execution_resource_cleanup do
    transient do
      cleanup_project { association(:project) }
    end

    account { cleanup_project.account }
    project { cleanup_project }
    agent_run { association :agent_run, project: cleanup_project }
    provisioning_intent { nil }
    runner_type { "local_docker" }
    resource_kind { "container" }
    provider_resource_id { SecureRandom.hex(12) }
    provider_resource_host { "local" }
    ownership_tags do
      {
        "paid.account_id" => account.id.to_s,
        "paid.project_id" => project.id.to_s,
        "paid.run_id" => agent_run.id.to_s,
        "paid.created_at" => Time.current.utc.iso8601
      }
    end
    attempts { 0 }
    status { "pending" }
    next_attempt_at { Time.current }

    trait :completed do
      status { "completed" }
      completed_at { Time.current }
    end
  end
end
