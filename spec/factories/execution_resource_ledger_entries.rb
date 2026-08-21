# frozen_string_literal: true

FactoryBot.define do
  factory :execution_resource_ledger_entry do
    transient do
      entry_account { association :account }
    end

    account { entry_account }
    project { association :project, account: entry_account }
    agent_run { nil }
    run_attempt { nil }
    runner_type { "docker" }
    backend { "local" }
    resource_kind { "primary_environment" }
    provider_resource_id { nil }
    tags { { "paid.managed" => "true", "paid.resource_kind" => "primary_environment" } }
    status { "provisioning" }
    cleanup_attempts { 0 }
    runner_handle { {} }

    trait :with_agent_run do
      agent_run { association :agent_run, project: project }
    end

    trait :service do
      resource_kind { "service" }
    end

    trait :sidecar do
      resource_kind { "sidecar" }
    end

    trait :workspace do
      resource_kind { "workspace" }
    end

    trait :network do
      resource_kind { "network" }
    end

    trait :preview_tunnel do
      resource_kind { "preview_tunnel" }
    end

    trait :temporary_storage do
      resource_kind { "temporary_storage" }
    end

    trait :active do
      status { "active" }
      activated_at { Time.current }
      provider_resource_id { "cont_abc123" }
    end

    trait :cleanup_pending do
      status { "cleanup_pending" }
      activated_at { Time.current }
      cleanup_requested_at { Time.current }
    end

    trait :deleted do
      status { "deleted" }
      activated_at { Time.current }
      cleanup_requested_at { Time.current }
      deleted_at { Time.current }
    end

    trait :orphaned do
      status { "orphaned" }
      orphaned_at { Time.current }
    end

    trait :cleanup_failed do
      status { "cleanup_failed" }
      activated_at { Time.current }
      cleanup_requested_at { Time.current }
      cleanup_attempts { 1 }
      cleanup_last_attempted_at { Time.current }
      cleanup_last_error { "provider timeout" }
      cleanup_failed_at { Time.current }
    end
  end
end
