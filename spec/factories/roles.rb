# frozen_string_literal: true

FactoryBot.define do
  factory :role do
    name { "member" }

    trait :owner do
      name { "owner" }
    end

    trait :admin do
      name { "admin" }
    end

    trait :member do
      name { "member" }
    end

    trait :viewer do
      name { "viewer" }
    end
  end
end
