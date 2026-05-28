# frozen_string_literal: true

FactoryBot.define do
  factory :context_intake_question do
    project { nil }
    sequence(:key) { |n| "context_question_#{n}" }
    question_text { "What does this product do?" }
    section_key { "product_purpose" }
    section_title { "Product Purpose" }
    category { section_key }
    round { 1 }
    section_order { 0 }
    display_order { 0 }
    required { false }
    is_follow_up { false }
    parent_question_key { nil }
    status { "approved" }
    provenance { "human" }
    active { true }
    conditions { {} }
    validation_rules { {} }
    metadata { {} }

    trait :pending_review do
      status { "pending_review" }
    end

    trait :follow_up do
      round { 2 }
      is_follow_up { true }
      provenance { "agent" }
    end
  end
end
