# frozen_string_literal: true

FactoryBot.define do
  factory :runner_auth_attempt do
    transient do
      project_account { association :account }
      project_owner { project_account }
    end

    account { project_account }
    project { association :project, account: project_account }
    runner_key { "claude" }
    attempt_stage { "materialization" }
    auth_source { "managed" }
    result { "materialized" }
    materialization_mode { "env" }
    container_host { "local" }
    feature_flag_state { "unregistered" }
    refresh_state { "not_applicable" }
    lease_state { "not_applicable" }
    duration_ms { 120 }
    retry_count { 0 }
    attempted_at { Time.current }
    metadata { { source: "factory" } }
  end

  trait :host_forwarded do
    auth_source { "host_forwarded" }
    materialization_mode { "host_mount" }
  end

  trait :managed do
    auth_source { "managed" }
    materialization_mode { "env" }
  end

  trait :api_key_proxy do
    auth_source { "api_key_proxy" }
    materialization_mode { "env" }
  end

  trait :failed do
    result { "failed" }
    failure_reason { "credential_expired" }
  end

  trait :refresh do
    attempt_stage { "refresh" }
    refresh_state { "refreshed" }
    result { "refreshed" }
  end

  trait :refresh_failed do
    attempt_stage { "refresh" }
    refresh_state { "refresh_failed" }
    result { "refresh_failed" }
    failure_reason { "exchange_refresh_token_failed" }
  end

  trait :lease do
    attempt_stage { "lease" }
    lease_state { "acquired" }
    result { "lease_acquired" }
  end

  trait :lease_timeout do
    attempt_stage { "lease" }
    lease_state { "timeout" }
    result { "lease_timeout" }
    failure_reason { "lock_timeout" }
  end

  trait :harvest do
    attempt_stage { "harvest" }
    result { "harvested" }
  end

  trait :harvest_failed do
    attempt_stage { "harvest" }
    result { "harvest_failed" }
    failure_reason { "exec_failed" }
  end

  trait :eligibility do
    attempt_stage { "eligibility" }
    result { "materialized" }
  end

  trait :remote_backend do
    container_host { "elguapo" }
    backend_supports_host_paths { false }
    backend_remote { true }
  end

  trait :with_runner_credential do
    runner_credential { association :runner_credential, account: project_account, runner_key: "claude" }
  end

  trait :with_agent_run do
    agent_run { association :agent_run, project: project }
  end
end
