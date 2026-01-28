# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    account
    sequence(:email) { |n| "user#{n}@example.com" }
    password { "password123" }
    password_confirmation { "password123" }
    name { Faker::Name.name }

    trait :owner do
      after(:create) do |user|
        user.add_role(:owner, user.account)
      end
    end

    trait :admin do
      after(:create) do |user|
        user.add_role(:admin, user.account)
      end
    end

    trait :member do
      after(:create) do |user|
        user.add_role(:member, user.account)
      end
    end

    trait :viewer do
      after(:create) do |user|
        user.add_role(:viewer, user.account)
      end
    end
  end
end
