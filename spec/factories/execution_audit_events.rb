# frozen_string_literal: true

FactoryBot.define do
  factory :execution_audit_event do
    transient do
      event_account { association :account }
    end

    account { event_account }
    project { association :project, account: event_account }
    event_name { "container.provisioned" }
    event_version { 1 }
    occurred_at { Time.current }
    actor_type { "system" }
    actor_id { "containers.provision" }
    runner_key { "claude" }
    backend { "local" }
    image_reference { "paid-agent:latest" }
    credential_classes { [ "proxy_restricted" ] }
    network_policy { { mode: "proxy_restricted", firewall: true } }
    resource_type { "container" }
    sequence(:resource_id) { |n| "container_#{n}" }
    correlation_id { "wf-123" }
    metadata { { source: "factory" } }

    trait :with_agent_run do
      agent_run { association :agent_run, project: project }
    end
  end
end
