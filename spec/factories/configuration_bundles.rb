# frozen_string_literal: true

FactoryBot.define do
  factory :configuration_bundle do
    account
    sequence(:name) { |n| "Configuration Bundle #{n}" }
    description { "Baseline bundle for optimizer training" }
    prompt_versions { { "planning" => 101, "coding" => 202 } }
    model_preferences { { "planning" => "gpt-5.4", "coding" => "codex" } }
    orchestration_config { { "max_parallel_agents" => 2, "max_iterations" => 3 } }
    thresholds { { "quality_gate" => 0.8, "cost_limit_cents" => 750 } }
    context_selector { { "project_size" => "medium" } }
    is_baseline { false }
    is_active { true }

    trait :global do
      account { nil }
    end

    trait :baseline do
      is_baseline { true }
    end
  end
end
