# frozen_string_literal: true

FactoryBot.define do
  factory :codex_login_session do
    account
    created_by { association :user, account: account }
    credential_name { "Codex Subscription Login" }
    external_id { SecureRandom.uuid }
    session_token { SecureRandom.hex(32) }
    status { "starting" }
    poll_interval { 5 }
    expires_at { CodexLoginSession::SESSION_TTL.from_now }
    metadata { {} }
    provider { "codex" }

    trait :awaiting_authorization do
      status { "awaiting_authorization" }
      device_code { "device-code-#{SecureRandom.hex(8)}" }
      user_code { "ABCD-WXYZ" }
      verification_uri { "https://auth.openai.com/device?user_code=ABCD-WXYZ" }
    end

    trait :completed do
      status { "completed" }
      completed_at { Time.current }
    end

    trait :failed do
      status { "failed" }
      error_message { "authorization denied" }
      failed_at { Time.current }
    end
  end
end
