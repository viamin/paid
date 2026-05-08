# frozen_string_literal: true

FactoryBot.define do
  factory :configuration_bundle_outcome do
    configuration_bundle
    agent_run { association :agent_run, :completed, configuration_bundle: configuration_bundle, strategy: :create }
    status { agent_run.status }
    quality_score { 0.8 }
    cost_cents { 125 }
    duration_seconds { 600 }
    completed_at { agent_run.completed_at || Time.current }
    component_scores { { "pr_created" => 1.0 } }
  end
end
