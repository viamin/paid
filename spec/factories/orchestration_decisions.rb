# frozen_string_literal: true

FactoryBot.define do
  factory :orchestration_decision do
    agent_run { association :agent_run, :completed }
    project { agent_run&.project || association(:project) }
    decision_type { "decompose" }
    actor { "workflow" }
    context do
      {
        issue: { complexity: "high", file_count: 12 },
        project: { language: "ruby", repository_size: "medium" }
      }
    end
    inputs do
      {
        strategies: %w[single parallel],
        available_agents: %w[claude_code codex]
      }
    end
    outputs do
      {
        selected_strategy: "parallel",
        agent_count: 2
      }
    end
    outcome_references do
      [
        { type: "agent_run", id: agent_run&.id },
        { type: "quality_metric", metric: "review_score" }
      ]
    end

    trait :without_agent_run do
      agent_run { nil }
      project { association :project }
    end
  end
end
