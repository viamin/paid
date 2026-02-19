# frozen_string_literal: true

FactoryBot.define do
  factory :github_token do
    account
    created_by { association :user, account: account }
    sequence(:name) { |n| "Token #{n}" }
    token { "ghp_#{SecureRandom.alphanumeric(36)}" }
    scopes { [ "repo", "read:org" ] }
    validation_status { "validated" }

    trait :pending_validation do
      validation_status { "pending" }
    end

    trait :validating do
      validation_status { "validating" }
    end

    trait :validation_failed do
      validation_status { "failed" }
      validation_error { "Token is invalid or has been revoked" }
    end

    trait :fine_grained do
      token { "github_pat_#{SecureRandom.alphanumeric(22)}_#{SecureRandom.alphanumeric(40)}" }
    end

    trait :expired do
      expires_at { 1.day.ago }
    end

    trait :expiring_soon do
      expires_at { 7.days.from_now }
    end

    trait :revoked do
      revoked_at { 1.hour.ago }
    end

    trait :recently_used do
      last_used_at { 1.hour.ago }
    end

    trait :without_creator do
      created_by { nil }
    end
  end
end
