# frozen_string_literal: true

FactoryBot.define do
  factory :knowledge_artifact do
    collector_run
    project { collector_run&.project_version&.project || association(:project) }
    collector_type { collector_run&.collector_type || "test" }
    artifact_type { "route" }
    scope_path { "app/controllers/users_controller.rb" }
    sequence(:identifier) { |n| "GET /api/users/#{n}" }
    content { '{"method": "GET", "path": "/api/users"}' }
    sequence(:content_hash) { |n| Digest::SHA256.hexdigest("artifact-#{n}") }
    metadata { {} }
    status { "active" }

    trait :stale do
      status { "stale" }
    end
  end
end
