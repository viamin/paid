# frozen_string_literal: true

FactoryBot.define do
  factory :pending_install_claim do
    account
    sequence(:github_installation_id) { |n| 30_000_000 + n }
    source { "callback_with_state" }
    state_token { SecureRandom.urlsafe_base64(32) }
    expires_at { Time.current + 1.hour }
  end
end
