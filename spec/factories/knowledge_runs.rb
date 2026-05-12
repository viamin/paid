# frozen_string_literal: true

FactoryBot.define do
  factory :knowledge_run do
    project
    operation_type { "embedding" }
    status { "pending" }
    final_runner { nil }
    runner_attempts { [] }
    total_tokens { 0 }
    proxy_token { SecureRandom.hex(32) }
    token_limit_status { nil }
    max_tokens { nil }

    trait :running do
      status { "running" }
    end

    trait :completed do
      status { "completed" }
    end

    trait :failed do
      status { "failed" }
    end

    trait :decision_drafting do
      operation_type { "decision_drafting" }
    end
  end
end
