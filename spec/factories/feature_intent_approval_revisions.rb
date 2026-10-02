# frozen_string_literal: true

FactoryBot.define do
  factory :feature_intent_approval_revision do
    feature_intent
    approved_by factory: :user
    approved_at { Time.current }
    source { "inbox" }
    pr_heads { {} }
    sequence(:revision_number) { |n| n }
  end
end
