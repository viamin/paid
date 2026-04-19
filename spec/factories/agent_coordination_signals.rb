# frozen_string_literal: true

FactoryBot.define do
  factory :agent_coordination_signal do
    source_agent_run { association :agent_run }
    parent_workflow_id { "parallel-workflow-#{SecureRandom.hex(6)}" }
    signal_type { "dependency_completed" }
    payload { {} }

    trait :files_changed do
      signal_type { "files_changed" }
      payload { { "files" => [ "app/models/user.rb", "spec/models/user_spec.rb" ] } }
    end

    trait :dependency_completed do
      signal_type { "dependency_completed" }
      payload { { "completed_at" => Time.current.iso8601, "branch_name" => "paid/feature-abc" } }
    end

    trait :dependency_failed do
      signal_type { "dependency_failed" }
      payload { { "error_message" => "Agent execution timed out", "failed_status" => "timeout" } }
    end

    trait :context_shared do
      signal_type { "context_shared" }
      payload { { "summary" => "Added User model with authentication" } }
    end

    trait :sequencing_hint do
      signal_type { "sequencing_hint" }
      payload { { "hint" => "Run database migrations before API tests" } }
    end

    trait :targeted do
      target_agent_run { association :agent_run }
    end
  end
end
