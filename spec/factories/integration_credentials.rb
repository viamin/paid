# frozen_string_literal: true

FactoryBot.define do
  factory :integration_credential do
    account
    created_by { association :user, account: account }
    sequence(:name) { |n| "Credential #{n}" }
    service_key { "claude" }
    category { "llm_provider" }
    auth_kind { "api_key" }
    secret { "sk-test-#{SecureRandom.hex(16)}" }
    metadata { {} }

    trait :oauth do
      auth_kind { "oauth_token" }
      secret { "oauth-#{SecureRandom.hex(16)}" }
    end

    trait :gitlab do
      service_key { "gitlab" }
      category { "repository" }
    end

    trait :jira do
      service_key { "jira" }
      category { "issue_tracking" }
    end

    trait :github_signing do
      service_key { "github_signing" }
      category { "signing" }
      auth_kind { "signing_token" }
      secret { "sign-#{SecureRandom.hex(16)}" }
    end

    trait :revoked do
      revoked_at { 1.hour.ago }
    end

    trait :expired do
      expires_at { 1.hour.ago }
    end
  end
end
