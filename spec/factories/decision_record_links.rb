# frozen_string_literal: true

FactoryBot.define do
  factory :decision_record_link do
    decision_record
    linkable_type { "AgentRun" }
    linkable_id { "1" }
    link_type { "implements" }

    trait :evidence do
      linkable_type { "KnowledgeChunk" }
      link_type { "evidence" }
    end

    trait :reverts do
      linkable_type { "DecisionRecord" }
      link_type { "reverts" }
    end
  end
end
