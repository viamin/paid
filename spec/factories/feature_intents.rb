# frozen_string_literal: true

FactoryBot.define do
  factory :feature_intent do
    project
    sequence(:title) { |n| "Feature intent #{n}" }
    brief { "Ship the approved feature." }
    status { "released" }
    approved_design_revision { "abc123superseded" }
    approved_revision_recorded_at { 1.day.ago }

    trait :ready_for_approval do
      status { "design_open" }
      criteria_clarity_state { "clear" }
      criteria_clarity_evaluated_at { 1.hour.ago }
    end

    trait :approved_waiting_for_merge do
      status { "approved_waiting_for_merge" }
      criteria_clarity_state { "clear" }
      criteria_clarity_evaluated_at { 1.hour.ago }
      approved_by factory: :user
      approved_at { 1.hour.ago }
    end
  end
end
