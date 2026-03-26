# frozen_string_literal: true

FactoryBot.define do
  factory :linear_token do
    account
    created_by { association :user, account: account }
    sequence(:name) { |n| "Linear Key #{n}" }
    token { "lin_api_#{SecureRandom.alphanumeric(32)}" }
    validation_status { "validated" }

    trait :revoked do
      revoked_at { 1.hour.ago }
    end

    trait :pending_validation do
      validation_status { "pending" }
    end
  end
end
