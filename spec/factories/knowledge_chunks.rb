# frozen_string_literal: true

FactoryBot.define do
  factory :knowledge_chunk do
    knowledge_artifact
    project { knowledge_artifact&.project }
    chunk_type { "definition" }
    sequence(:content) { |n| "Chunk content #{n}" }
    sequence(:content_hash) { |n| Digest::SHA256.hexdigest("chunk-#{n}") }
    scope_tags { [] }
    status { "active" }
    add_attribute(:sequence) { 0 }
  end
end
