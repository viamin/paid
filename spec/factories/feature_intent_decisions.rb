# frozen_string_literal: true

FactoryBot.define do
  factory :feature_intent_decision do
    feature_intent
    kind { "question" }
    design_claim { "The feature must support X." }
    prompt { "Should X apply to existing records or only new ones?" }
    status { "open" }

    trait :inferred_decision do
      kind { "inferred_decision" }
      prompt { "[inferred] Assuming X applies to new records only." }
    end

    trait :resolved do
      status { "resolved" }
      answer { "New records only." }
      resolved_by factory: :user
      resolved_at { 1.hour.ago }
    end
  end
end
