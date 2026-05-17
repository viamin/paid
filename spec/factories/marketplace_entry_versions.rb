# frozen_string_literal: true

FactoryBot.define do
  factory :marketplace_entry_version do
    marketplace_entry
    sequence(:version) { |n| n }
    canonical_artifact do
      {
        "attachment_strategy" => "prompt_append",
        "content" => "Follow the repository coding workflow."
      }
    end
    renderers { {} }
    compatibility_constraints { {} }
    review_metadata { {} }
  end
end
