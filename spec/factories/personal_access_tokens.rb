# frozen_string_literal: true

FactoryBot.define do
  factory :personal_access_token do
    association :user
    account { user.account }
    sequence(:name) { |n| "Mobile #{n}" }
    scopes { %w[inbox chat] }

    transient do
      plaintext { "paid_pat_#{SecureRandom.urlsafe_base64(32)}" }
    end

    token_digest { PersonalAccessToken.digest(plaintext) }
  end
end
