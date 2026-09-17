# frozen_string_literal: true

FactoryBot.define do
  factory :feature_intent do
    project
    sequence(:title) { |n| "Feature intent #{n}" }
    brief { "Ship the approved feature." }
    status { "released" }
    approved_design_revision { "abc123superseded" }
    approved_revision_recorded_at { 1.day.ago }
  end
end
