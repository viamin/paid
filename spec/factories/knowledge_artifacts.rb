# frozen_string_literal: true

FactoryBot.define do
  factory :knowledge_artifact do
    collector_run
    project { collector_run.project_version.project }

    artifact_type { "route" }
    identifier { "GET /api/users" }
    content { '{"method":"GET","path":"/api/users"}' }
    sequence(:content_hash) { |n| Digest::SHA256.hexdigest("artifact-#{n}") }
    status { "active" }
    metadata { {} }
  end
end
