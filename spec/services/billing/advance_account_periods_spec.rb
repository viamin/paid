# frozen_string_literal: true

require "rails_helper"

RSpec.describe Billing::AdvanceAccountPeriods do
  let(:account) { create(:account) }
  let!(:plan) { create(:billing_plan, account: account, period_type: "monthly") }

  describe ".call" do
    it "creates an initial open billing period when one does not exist" do
      freeze_time do
        result = described_class.call(account: account)

        period = account.billing_periods.order(:starts_at).last
        expect(result.opened_period_ids).to eq([ period.id ])
        expect(period).to be_open
        expect(period.starts_at).to eq(Time.current.beginning_of_month)
        expect(period.ends_at).to eq(Time.current.beginning_of_month.next_month)
      end
    end

    it "closes due periods, generates an invoice, and opens the next period" do
      freeze_time do
        previous_period = create(
          :billing_period,
          account: account,
          billing_plan: plan,
          starts_at: 1.month.ago.beginning_of_month,
          ends_at: Time.current.beginning_of_month,
          status: "open"
        )

        result = described_class.call(account: account)

        expect(result.closed_period_ids).to eq([ previous_period.id ])
        expect(result.generated_invoice_ids.size).to eq(1)
        expect(result.issued_invoice_ids.size).to eq(1)
        expect(account.billing_invoices.last).to be_issued

        current_period = account.billing_periods.open.order(:starts_at).last
        expect(current_period.starts_at).to eq(Time.current.beginning_of_month)
        expect(current_period.ends_at).to eq(Time.current.beginning_of_month.next_month)
      end
    end

    it "issues existing draft invoices for already invoiced periods" do
      freeze_time do
        period = create(:billing_period, :invoiced, account: account, billing_plan: plan, ends_at: 1.day.ago)
        invoice = create(:billing_invoice, account: account, billing_period: period, status: "draft")

        result = described_class.call(account: account)

        expect(result.generated_invoice_ids).to be_empty
        expect(result.issued_invoice_ids).to eq([ invoice.id ])
        expect(invoice.reload).to be_issued
        expect(invoice.payment_sync_status).to eq("not_configured")
      end
    end
  end
end
