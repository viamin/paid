# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    account
    sequence(:email) { |n| "user#{n}@example.com" }
    password { "password123" }
    password_confirmation { "password123" }
    name { Faker::Name.name }
  end
end
