# frozen_string_literal: true

FactoryBot.define do
  factory :quality_recovery_action do
    project
    action_type { "prompt_rollback" }
    status { "pending" }
    diagnosis { {} }
    parameters { {} }
    result { {} }

    trait :executing do
      status { "executing" }
      executed_at { Time.current }
    end

    trait :executed do
      status { "executed" }
      executed_at { 5.minutes.ago }
      quality_before { 0.65 }
      result { { status: "rolled_back" } }
    end

    trait :evaluated do
      status { "evaluated" }
      executed_at { 10.minutes.ago }
      evaluated_at { Time.current }
      quality_before { 0.55 }
      quality_after { 0.82 }
      result { { status: "rolled_back" } }
    end

    trait :failed do
      status { "failed" }
      executed_at { 5.minutes.ago }
      result { { error: { error_class: "StandardError", error_message: "Something went wrong" } } }
    end

    trait :prompt_rollback do
      action_type { "prompt_rollback" }
    end

    trait :model_change do
      action_type { "model_change" }
    end

    trait :prompt_evolution do
      action_type { "prompt_evolution" }
    end

    trait :model_escalation do
      action_type { "model_escalation" }
    end

    trait :final_pause do
      action_type { "final_pause" }
    end

    trait :config_adjustment do
      action_type { "config_adjustment" }
    end

    trait :resume_with_monitoring do
      action_type { "resume_with_monitoring" }
    end
  end
end
