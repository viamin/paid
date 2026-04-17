# frozen_string_literal: true

FactoryBot.define do
  factory :billing_invoice do
    account
    billing_period
    status { "draft" }
    subtotal_cents { 0 }
    tax_cents { 0 }
    total_cents { 0 }
    metadata { {} }

    trait :issued do
      status { "issued" }
      issued_at { Time.current }
    end

    trait :paid do
      status { "paid" }
      issued_at { 1.week.ago }
      paid_at { Time.current }
    end
  end
end
