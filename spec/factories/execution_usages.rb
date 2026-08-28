# frozen_string_literal: true

FactoryBot.define do
  factory :execution_usage do
    agent_run { association :agent_run, :completed }
    runner_backend { "local" }
    provider_resource_id { "fly-machine-abc123" }
    provisioned_at { 1.hour.ago }
    execution_started_at { 1.hour.ago }
    completed_at { 30.minutes.ago }
    terminated_at { 30.minutes.ago }
    billed_duration_seconds { 1800 }
    requested_cpu_cores { BigDecimal("1.0") }
    requested_memory_mib { 2048 }
    requested_disk_gb { 20 }
    termination_reason { "completed" }
    infra_cost_cents { 0 }
    rate_cents_per_hour { 0 }

    trait :completed do
      termination_reason { "completed" }
    end

    trait :cancelled do
      termination_reason { "cancelled" }
    end

    trait :failed do
      termination_reason { "failed" }
    end

    trait :timed_out do
      termination_reason { "timed_out" }
    end

    trait :evicted do
      termination_reason { "evicted" }
    end
  end
end
