# frozen_string_literal: true

FactoryBot.define do
  factory :container_metric do
    agent_run { association :agent_run, :running }
    container_id { "abc123def456" }
    cpu_percent { 25.5 }
    memory_bytes { 1_073_741_824 }
    memory_limit_bytes { 4_294_967_296 }
    memory_percent { 25.0 }
    pids_count { 42 }
    recorded_at { Time.current }
  end
end
