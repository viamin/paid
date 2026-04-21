# frozen_string_literal: true

require "rails_helper"

RSpec.describe Billing::GenerateInvoice do
  let(:account) { create(:account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }
  let(:plan) do
    create(:billing_plan, account: account, billing_model: "per_token",
           base_rate_cents: 1_000, per_token_rate_cents: 0.003, included_tokens: 100_000)
  end
  let(:billing_period) do
    create(:billing_period, account: account, billing_plan: plan,
           starts_at: 1.month.ago, ends_at: Time.current, status: "closed")
  end

  before do
    agent_run = create(:agent_run, :running, project: project)
    create(:token_usage, agent_run: agent_run, input_tokens: 200_000, output_tokens: 50_000,
           cost_cents: 50, llm_model: "claude-sonnet-4.5", request_type: "agent")
  end

  describe ".call" do
    it "creates an invoice with line items" do
      invoice = described_class.call(billing_period: billing_period)

      expect(invoice).to be_a(BillingInvoice)
      expect(invoice.status).to eq("draft")
      expect(invoice.billing_line_items).not_to be_empty
    end

    it "marks the billing period as invoiced" do
      described_class.call(billing_period: billing_period)

      expect(billing_period.reload.status).to eq("invoiced")
    end

    it "returns the existing invoice when the billing period is already invoiced" do
      invoice = described_class.call(billing_period: billing_period)

      expect(described_class.call(billing_period: billing_period)).to eq(invoice)
      expect(billing_period.billing_invoices.count).to eq(1)
    end

    it "calculates invoice totals from line items" do
      invoice = described_class.call(billing_period: billing_period)

      expect(invoice.subtotal_cents).to eq(invoice.billing_line_items.sum(:total_cents))
      expect(invoice.total_cents).to eq(invoice.subtotal_cents + invoice.tax_cents)
    end

    it "updates the billing period usage summary" do
      described_class.call(billing_period: billing_period)

      billing_period.reload
      expect(billing_period.total_input_tokens).to eq(200_000)
      expect(billing_period.total_output_tokens).to eq(50_000)
      expect(billing_period.total_runs).to eq(1)
    end

    it "rejects open billing periods" do
      billing_period.update!(status: "open")

      expect { described_class.call(billing_period: billing_period) }
        .to raise_error(described_class::PeriodNotClosedError, "Billing period must be closed before invoicing")
      expect(billing_period.billing_invoices).to be_empty
      expect(billing_period.reload).to be_open
    end
  end
end
