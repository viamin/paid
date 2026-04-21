# frozen_string_literal: true

class BillingLineItem < ApplicationRecord
  LINE_ITEM_TYPES = %w[base_rate token_usage run_usage project_usage overage_tokens overage_runs adjustment].freeze

  belongs_to :billing_invoice

  validates :description, presence: true
  validates :line_item_type, presence: true, inclusion: { in: LINE_ITEM_TYPES }
  validates :quantity, numericality: { greater_than_or_equal_to: 0 }
  validates :unit_price_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :total_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
