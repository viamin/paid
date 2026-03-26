# frozen_string_literal: true

FactoryBot.define do
  factory :knowledge_artifact do
    collector_run
    project { collector_run&.project_version&.project || association(:project) }
    artifact_type { "route" }
    identifier { "POST /api/users" }
    content { '{"method": "POST", "path": "/api/users"}' }
    sequence(:content_hash) { |n| Digest::SHA256.hexdigest("artifact-#{n}") }
    status { "active" }
  end
end
