# frozen_string_literal: true

FactoryBot.define do
  factory :agent_run_log do
    agent_run
    log_type { "stdout" }
    sequence(:content) { |n| "Log message #{n}" }

    trait :stdout do
      log_type { "stdout" }
      content { "Standard output message" }
    end

    trait :stderr do
      log_type { "stderr" }
      content { "Error output message" }
    end

    trait :system do
      log_type { "system" }
      content { "System event: container started" }
    end

    trait :metric do
      log_type { "metric" }
      content { "tokens_used: 1500" }
      metadata { { tokens_input: 1000, tokens_output: 500 } }
    end

    trait :with_metadata do
      metadata { { key: "value", timestamp: Time.current.iso8601 } }
    end
  end
end
