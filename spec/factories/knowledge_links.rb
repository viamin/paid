# frozen_string_literal: true

FactoryBot.define do
  factory :knowledge_link do
    source_chunk { association :knowledge_chunk }
    target_chunk { association :knowledge_chunk }
    link_type { "relates_to" }
    weight { 1.0 }
  end
end
