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

    trait :long_lived do
      long_lived { true }
    end

    trait :revoked do
      revoked_at { 1.hour.ago }
    end
  end
end
