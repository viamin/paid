# frozen_string_literal: true

module Billing
  class GenerateInvoice
    PeriodNotClosedError = Class.new(StandardError)

    attr_reader :billing_period

    def initialize(billing_period:)
      @billing_period = billing_period
    end

    def self.call(...)
      new(...).call
    end

    def call
      return existing_invoice if billing_period.invoiced?

      invoice = nil
      ActiveRecord::Base.transaction do
        billing_period.lock!
        invoice = if billing_period.invoiced?
          existing_invoice
        elsif billing_period.closed?
          GeneratePeriodSummary.call(billing_period: billing_period)
          create_invoice(CalculateCharges.call(billing_period: billing_period))
        else
          raise PeriodNotClosedError, "Billing period must be closed before invoicing"
        end
      end

      invoice
    end

    private

    def existing_invoice
      BillingInvoice.where(billing_period_id: billing_period.id).last
    end

    def create_invoice(line_item_attrs)
      invoice = BillingInvoice.create!(
        account_id: billing_period.account_id,
        billing_period_id: billing_period.id,
        status: "draft"
      )

      line_item_attrs.each { |attrs| invoice.billing_line_items.create!(attrs) }
      invoice.recalculate_totals!
      billing_period.update!(status: "invoiced")
      invoice
    end
  end
end
