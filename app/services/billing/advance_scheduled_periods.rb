# frozen_string_literal: true

module Billing
  class AdvanceScheduledPeriods
    Result = Struct.new(
      :accounts_processed,
      :periods_closed,
      :periods_opened,
      :invoices_generated,
      :invoices_issued,
      keyword_init: true
    )

    attr_reader :as_of

    def initialize(as_of: Time.current)
      @as_of = as_of
    end

    def self.call(...)
      new(...).call
    end

    def call
      Account.joins(:billing_plans).merge(BillingPlan.active).distinct.find_each.with_object(initial_result) do |account, summary|
        account_result = AdvanceAccountPeriods.call(account: account, as_of: as_of)
        next if unchanged?(account_result)

        summary.accounts_processed += 1
        summary.periods_closed += account_result.closed_period_ids.size
        summary.periods_opened += account_result.opened_period_ids.size
        summary.invoices_generated += account_result.generated_invoice_ids.size
        summary.invoices_issued += account_result.issued_invoice_ids.size
      end
    end

    private

    def initial_result
      Result.new(
        accounts_processed: 0,
        periods_closed: 0,
        periods_opened: 0,
        invoices_generated: 0,
        invoices_issued: 0
      )
    end

    def unchanged?(account_result)
      account_result.closed_period_ids.empty? &&
        account_result.opened_period_ids.empty? &&
        account_result.generated_invoice_ids.empty? &&
        account_result.issued_invoice_ids.empty?
    end
  end
end
