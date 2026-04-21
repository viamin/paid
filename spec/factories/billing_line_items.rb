# frozen_string_literal: true

FactoryBot.define do
  factory :billing_line_item do
    billing_invoice
    description { "Token usage charges" }
    line_item_type { "token_usage" }
    quantity { 1000 }
    unit_price_cents { 1 }
    total_cents { 1000 }
    metadata { {} }
  end
end
