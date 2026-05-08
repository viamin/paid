# frozen_string_literal: true

FactoryBot.define do
  factory :bundle_outcome do
    configuration_bundle
    agent_run { association :agent_run, :completed, project: association(:project, account: configuration_bundle.account) }
    project { agent_run.project }
    context_features { { "project_language" => "ruby", "issue_complexity" => 0.6 } }
    outcome_score { 0.72 }
    component_scores { { "quality_score" => 0.72, "pr_created" => 1.0 } }
  end
end
