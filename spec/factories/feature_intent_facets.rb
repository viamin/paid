# frozen_string_literal: true

FactoryBot.define do
  factory :feature_intent_facet do
    feature_intent
    account { feature_intent.project.account }
    sequence(:name) { |n| "Facet #{n}" }
    design_claim { "The feature preserves the selected workflow." }
  end

  factory :feature_intent_facet_direction do
    feature_intent_facet
    account { feature_intent_facet.account }
    sequence(:name) { |n| "Direction #{n}" }
    description { "A candidate implementation direction." }
  end
end
