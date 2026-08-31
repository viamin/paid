# frozen_string_literal: true

FactoryBot.define do
  factory :login_session do
    account
    created_by { association :user, account: account }
    credential_name { "Login Session" }
    external_id { SecureRandom.uuid }
    session_token { SecureRandom.hex(32) }
    status { "starting" }
    expires_at { 15.minutes.from_now }
    metadata { {} }
    provider { "claude" }

    factory :claude_login_session_new, class: "LoginSession" do
      provider { "claude" }
      credential_name { "Claude Browser Login" }

      trait :awaiting_code do
        status { "awaiting_code" }
        oauth_url { "https://claude.com/cai/oauth/authorize?code=true" }
      end

      trait :completed do
        status { "completed" }
        completed_at { Time.current }
      end
    end

    factory :codex_login_session_new, class: "LoginSession" do
      provider { "codex" }
      credential_name { "Codex Subscription Login" }
      poll_interval { 5 }

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
end
