# frozen_string_literal: true

FactoryBot.define do
  factory :model_availability_check do
    llm_model
    runner_key { "codex" }
    auth_type { "subscription" }
    account { nil }
    status { "available" }
    source { "agent_harness_compat" }
    checked_at { Time.current }
  end
end
