# frozen_string_literal: true

FactoryBot.define do
  factory :account_membership do
    user
    account
    role { :member }

    trait :owner do
      role { :owner }
    end

    trait :admin do
      role { :admin }
    end

    trait :member do
      role { :member }
    end

    trait :viewer do
      role { :viewer }
    end
  end
end
