# frozen_string_literal: true

FactoryBot.define do
  factory :runner_credential do
    transient do
      runner_user { association :user }
      runner { association :runner, user: runner_user }
    end

    account { runner.user.account }
    runner_key { runner.runner_key }
    created_by { association :user, account: account }
    token { "sk-ant-oat01-#{SecureRandom.hex(32)}" }
    long_lived { false }

    after(:build) do |credential|
      credential.name ||= "#{Runner.display_name_for(credential.runner_key)} credential #{SecureRandom.hex(4)}" if credential.has_attribute?(:name)
      credential.auth_kind ||= "oauth_token" if credential.has_attribute?(:auth_kind)
      credential.metadata ||= {} if credential.has_attribute?(:metadata)
    end

    trait :long_lived do
      long_lived { true }
    end

    trait :expired do
      after(:build) do |credential|
        credential.expires_at = 1.hour.ago if credential.has_attribute?(:expires_at)
      end
    end

    trait :revoked do
      revoked_at { 1.hour.ago }
    end
  end
end
