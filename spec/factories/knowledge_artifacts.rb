# frozen_string_literal: true

FactoryBot.define do
  factory :knowledge_artifact do
    collector_run
    project { collector_run.project_version.project }
    artifact_type { "route" }
    scope_path { "app/controllers/users_controller.rb" }
    sequence(:identifier) { |n| "GET /api/users/#{n}" }
    content { '{"method": "GET", "path": "/api/users"}' }
    content_hash { Digest::SHA256.hexdigest(content) }
    metadata { {} }
    status { "active" }

    trait :stale do
      status { "stale" }
    end
  end
end
