# frozen_string_literal: true

require "rails_helper"

RSpec.describe BillingInvoice do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:billing_period) }
    it { is_expected.to have_many(:billing_line_items).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_numericality_of(:subtotal_cents).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:tax_cents).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:total_cents).is_greater_than_or_equal_to(0) }

    it "validates billing period belongs to the same account" do
      invoice = build(:billing_invoice, account: create(:account), billing_period: create(:billing_period))

      expect(invoice).not_to be_valid
      expect(invoice.errors[:billing_period]).to include("must belong to the same account")
    end
  end

  describe "#issue!" do
    it "sets status to issued and records timestamp" do
      invoice = create(:billing_invoice, status: "draft")

      freeze_time do
        invoice.issue!
        expect(invoice.status).to eq("issued")
        expect(invoice.issued_at).to eq(Time.current)
      end
    end
  end

  describe "#mark_paid!" do
    it "sets status to paid and records timestamp" do
      invoice = create(:billing_invoice, status: "issued")

      freeze_time do
        invoice.mark_paid!
        expect(invoice.status).to eq("paid")
        expect(invoice.paid_at).to eq(Time.current)
      end
    end
  end

  describe "#void!" do
    it "sets status to void" do
      invoice = create(:billing_invoice, status: "draft")
      invoice.void!
      expect(invoice.status).to eq("void")
    end
  end

  describe "#recalculate_totals!" do
    it "sums line item totals into subtotal and total" do
      invoice = create(:billing_invoice, tax_cents: 100)
      create(:billing_line_item, billing_invoice: invoice, total_cents: 500)
      create(:billing_line_item, billing_invoice: invoice, total_cents: 300)

      invoice.recalculate_totals!
      expect(invoice.subtotal_cents).to eq(800)
      expect(invoice.total_cents).to eq(900)
    end
  end

  describe "#payment_sync_status" do
    it "defaults to not_configured when no external payment sync is present" do
      invoice = create(:billing_invoice)

      expect(invoice.payment_sync_status).to eq("not_configured")
    end

    it "returns paid for paid invoices" do
      invoice = create(:billing_invoice, :paid)

      expect(invoice.payment_sync_status).to eq("paid")
    end
  end
end
