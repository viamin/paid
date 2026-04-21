# frozen_string_literal: true

require "rails_helper"

RSpec.describe BillingLineItem do
  describe "associations" do
    it { is_expected.to belong_to(:billing_invoice) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:description) }
    it { is_expected.to validate_presence_of(:line_item_type) }
    it { is_expected.to validate_inclusion_of(:line_item_type).in_array(described_class::LINE_ITEM_TYPES) }
    it { is_expected.to validate_numericality_of(:quantity).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:unit_price_cents).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:total_cents).is_greater_than_or_equal_to(0) }
  end
end
