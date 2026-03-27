# frozen_string_literal: true

FactoryBot.define do
  factory :knowledge_audit_event do
    project
    event_type { "artifact_created" }
    actor_type { "collector" }
    sequence(:actor_id) { |n| "collector_run_#{n}" }
    target_type { "KnowledgeArtifact" }
    sequence(:target_id) { |n| n.to_s }
    details { { artifact_type: "route", identifier: "GET /api/users" } }
  end
end
