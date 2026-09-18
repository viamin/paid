# frozen_string_literal: true

FactoryBot.define do
  factory :intent_conformance_decision do
    issue { association :issue, :pull_request }
    actor { association :user }
    action { IntentConformanceDecision::FIX_PR }
    head_sha { SecureRandom.hex(20) }
    reason { "Bring the PR back within the approved design's scope." }

    trait :bounded_exception do
      action { IntentConformanceDecision::BOUNDED_EXCEPTION }
      reason { "Implementation detail only; product contract unchanged." }
    end

    trait :design_amendment do
      action { IntentConformanceDecision::DESIGN_AMENDMENT }
      reason { "Product behavior should change; routing through design review." }
    end
  end
end
