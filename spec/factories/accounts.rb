# frozen_string_literal: true

FactoryBot.define do
  factory :account do
    sequence(:name) { |n| "Account #{n}-#{SecureRandom.hex(3)}" }
    sequence(:slug) { |n| "account-#{n}-#{SecureRandom.hex(3)}" }
  end
end
