# frozen_string_literal: true

FactoryBot.define do
  factory :knowledge_chunk do
    knowledge_artifact
    project { knowledge_artifact.project }
    chunk_type { "definition" }
    sequence(:content) { |n| "Chunk content #{n}" }
    content_hash { Digest::SHA256.hexdigest(content) }
    scope_tags { [] }
    status { "active" }
    add_attribute(:sequence) { 0 }
  end
end
