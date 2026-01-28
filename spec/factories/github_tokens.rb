# frozen_string_literal: true

FactoryBot.define do
  factory :github_token do
    account
    association :created_by, factory: :user
    sequence(:name) { |n| "Token #{n}" }
    token { "ghp_#{SecureRandom.alphanumeric(36)}" }
    scopes { [ "repo", "read:org" ] }

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
