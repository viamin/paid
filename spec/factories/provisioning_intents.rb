# frozen_string_literal: true

FactoryBot.define do
  factory :provisioning_intent do
    transient do
      intent_project { nil }
    end

    project { intent_project || association(:project) }
    agent_run { association :agent_run, project: project }
    account { project&.account || association(:account) }
    resource_kind { "container" }
    runner_type { "local_docker" }
    environment { "test" }
    attempt { 0 }
    ownership_tags do
      {
        "paid.environment" => "test",
        "paid.account" => account_id.to_s,
        "paid.account_id" => account_id.to_s,
        "paid.project" => project.id.to_s,
        "paid.project_id" => project.id.to_s,
        "paid.run" => agent_run.id.to_s,
        "paid.run_id" => agent_run.id.to_s,
        "paid.resource" => "container",
        "paid.created_at" => Time.current.utc.iso8601
      }
    end
    tagging_supported { true }
    status { "pending" }
    metadata { {} }
  end
end
