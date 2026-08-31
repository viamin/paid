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
  end
end
