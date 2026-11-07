# frozen_string_literal: true

FactoryBot.define do
  factory :project_delegation_posture do
    account { project.account }
    project
    level { "bounded_delivery" }
    enabled_action_classes { BoundedDelegatedAction::ACTIONS }
    selected_by { association :user, account: }
    selected_at { Time.current }

    trait :conservative do
      level { "conservative" }
      enabled_action_classes { [] }
    end
  end
end
