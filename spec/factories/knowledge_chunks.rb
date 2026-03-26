# frozen_string_literal: true

FactoryBot.define do
  factory :knowledge_chunk do
    knowledge_artifact
    project { knowledge_artifact.project }

    chunk_type { "definition" }
    content { "GET /api/users - Returns a list of users" }
    sequence(:content_hash) { |n| Digest::SHA256.hexdigest("chunk-#{n}") }
    status { "active" }
    scope_tags { [ "controller", "api" ] }
    add_attribute(:sequence) { 0 }
  end
end
