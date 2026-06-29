# frozen_string_literal: true

FactoryBot.define do
  factory :runner_credential do
    account
    created_by { association :user, account: account }
    sequence(:name) { |n| "Runner Credential #{n}" }
    runner_key { "claude" }
    auth_kind { "oauth_token" }
    token { "sk-ant-oat01-#{SecureRandom.hex(16)}" }
    long_lived { false }
    metadata { {} }

    trait :long_lived do
      long_lived { true }
    end

    trait :api_key do
      auth_kind { "api_key" }
      token { "sk-#{SecureRandom.hex(16)}" }
    end

    trait :codex do
      runner_key { "codex" }
    end

    trait :gemini do
      runner_key { "gemini" }
    end

    trait :copilot do
      runner_key { "copilot" }
    end

    trait :revoked do
      revoked_at { 1.hour.ago }
    end

    trait :expired do
      expires_at { 1.hour.ago }
    end
  end
end
