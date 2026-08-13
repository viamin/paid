# frozen_string_literal: true

FactoryBot.define do
  factory :context_intake_response do
    context_intake_session
    sequence(:question_key) { |n| "question_#{n}" }
    question_text { "What does this product do?" }
    section { "product_purpose" }
    add_attribute(:sequence) { 0 }
    is_follow_up { false }
    skipped { false }
    provenance { "human" }

    trait :answered do
      answer_text { "This product helps teams automate software development." }
    end

    trait :skipped do
      skipped { true }
    end

    trait :follow_up do
      is_follow_up { true }
      provenance { "agent" }
    end
  end
end
