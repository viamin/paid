# frozen_string_literal: true

FactoryBot.define do
  factory :knowledge_usage_stat do
    agent_run
    project { agent_run&.project || association(:project) }
    artifact_type { "route" }
    goal { "analyze_issue" }
    context_type { "bundle" }
    artifact_count { 10 }
    chunk_count { 10 }
    token_count { 300 }
    metadata { {} }
  end
end
