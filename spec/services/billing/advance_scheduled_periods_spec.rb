# frozen_string_literal: true

require "rails_helper"

RSpec.describe Billing::AdvanceScheduledPeriods do
  describe ".call" do
    it "summarizes scheduled billing work across accounts" do
      first_account = create(:account)
      second_account = create(:account)
      first_plan = create(:billing_plan, account: first_account)
      create(:billing_plan, account: second_account)

      create(
        :billing_period,
        account: first_account,
        billing_plan: first_plan,
        starts_at: 1.month.ago.beginning_of_month,
        ends_at: Time.current.beginning_of_month,
        status: "open"
      )

      freeze_time do
        result = described_class.call

        expect(result.accounts_processed).to eq(2)
        expect(result.periods_closed).to eq(1)
        expect(result.periods_opened).to eq(2)
        expect(result.invoices_generated).to eq(1)
        expect(result.invoices_issued).to eq(1)
      end
    end
  end
end
