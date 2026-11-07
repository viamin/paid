# frozen_string_literal: true

FactoryBot.define do
  factory :project_delegation_event do
    association :account
    association :project
    association :actor, factory: :user
    action { "posture_selected" }
    posture { "conservative" }
    policy_signature { "sha256:#{SecureRandom.hex(32)}" }
    metadata { {} }

    trait :bounded_delivery do
      posture { "bounded_delivery" }
      metadata { { "enabled_actions" => { "implementation_choice" => true } } }
    end

    trait :conservative do
      posture { "conservative" }
    end

    trait :without_actor do
      actor { nil }
    end
  end
end
