# frozen_string_literal: true

class BillingPeriodManagementJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "billing_period_management"
  )

  def perform
    summary = Billing::AdvanceScheduledPeriods.call

    Rails.logger.info(
      message: "billing.period_management.completed",
      accounts_processed: summary.accounts_processed,
      periods_closed: summary.periods_closed,
      periods_opened: summary.periods_opened,
      invoices_generated: summary.invoices_generated,
      invoices_issued: summary.invoices_issued
    )
  end
end
