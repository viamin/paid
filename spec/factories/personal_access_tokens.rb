# frozen_string_literal: true

FactoryBot.define do
  factory :personal_access_token do
    association :user
    account { user.account }
    sequence(:name) { |n| "Mobile token #{n}" }
    scopes { PersonalAccessToken::DEFAULT_SCOPES }

    transient do
      plaintext { PersonalAccessToken.generate_plaintext }
    end

    token_digest { PersonalAccessToken.digest(plaintext) }

    trait :expired do
      expires_at { 1.day.ago }
    end

    trait :revoked do
      revoked_at { 1.hour.ago }
    end

    trait :recently_used do
      last_used_at { 1.hour.ago }
    end
  end
end
