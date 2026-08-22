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
    ownership_tags { { "paid.environment" => "test", "paid.account" => account_id.to_s, "paid.resource" => "container" } }
    tagging_supported { true }
    status { "pending" }
    metadata { {} }
  end
end
