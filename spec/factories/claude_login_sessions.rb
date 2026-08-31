# frozen_string_literal: true

FactoryBot.define do
  factory :claude_login_session do
    account
    created_by { association :user, account: account }
    credential_name { "Claude Browser Login" }
    external_id { SecureRandom.uuid }
    session_token { SecureRandom.hex(32) }
    status { "starting" }
    expires_at { 15.minutes.from_now }
    metadata { {} }
    provider { "claude" }

    trait :awaiting_code do
      status { "awaiting_code" }
      oauth_url { "https://claude.com/cai/oauth/authorize?code=true" }
    end

    trait :completed do
      status { "completed" }
      completed_at { Time.current }
    end
  end
end
