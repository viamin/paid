# frozen_string_literal: true

require "rails_helper"

RSpec.describe BillingPeriodManagementJob do
  let(:summary) do
    Billing::AdvanceScheduledPeriods::Result.new(
      accounts_processed: 2,
      periods_closed: 1,
      periods_opened: 2,
      invoices_generated: 1,
      invoices_issued: 1
    )
  end

  describe "#perform" do
    it "runs the scheduled billing advancement flow" do
      allow(Billing::AdvanceScheduledPeriods).to receive(:call).and_return(summary)
      allow(Rails.logger).to receive(:info)

      described_class.perform_now

      expect(Billing::AdvanceScheduledPeriods).to have_received(:call)
      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "billing.period_management.completed",
          accounts_processed: 2,
          periods_closed: 1,
          periods_opened: 2,
          invoices_generated: 1,
          invoices_issued: 1
        )
      )
    end
  end
end
