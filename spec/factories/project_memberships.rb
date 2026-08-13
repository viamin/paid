# frozen_string_literal: true

FactoryBot.define do
  factory :project_membership do
    user
    project
    role { :member }

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
