# frozen_string_literal: true

module Billing
  class GenerateInvoice
    attr_reader :billing_period

    def initialize(billing_period:)
      @billing_period = billing_period
    end

    def self.call(...)
      new(...).call
    end

    def call
      GeneratePeriodSummary.call(billing_period: billing_period)
      line_item_attrs = CalculateCharges.call(billing_period: billing_period)

      invoice = nil
      ActiveRecord::Base.transaction do
        invoice = BillingInvoice.create!(
          account_id: billing_period.account_id,
          billing_period_id: billing_period.id,
          status: "draft"
        )

        line_item_attrs.each do |attrs|
          invoice.billing_line_items.create!(attrs)
        end

        invoice.recalculate_totals!
        billing_period.update!(status: "invoiced")
      end

      invoice
    end
  end
end
