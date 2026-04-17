# frozen_string_literal: true

require "rails_helper"

RSpec.describe BillingPeriod do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:billing_plan) }
    it { is_expected.to have_many(:billing_invoices).dependent(:restrict_with_error) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:period_type) }
    it { is_expected.to validate_inclusion_of(:period_type).in_array(described_class::PERIOD_TYPES) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_presence_of(:starts_at) }
    it { is_expected.to validate_presence_of(:ends_at) }
    it { is_expected.to validate_numericality_of(:total_cost_cents).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:total_runs).is_greater_than_or_equal_to(0) }

    it "validates ends_at is after starts_at" do
      period = build(:billing_period, starts_at: Time.current, ends_at: 1.day.ago)
      expect(period).not_to be_valid
      expect(period.errors[:ends_at]).to include("must be after starts_at")
    end
  end

  describe "scopes" do
    it ".open returns open periods" do
      open_period = create(:billing_period, status: "open")
      create(:billing_period, :closed)

      expect(described_class.open).to eq([ open_period ])
    end

    it ".for_date returns periods containing the given date" do
      period = create(:billing_period, starts_at: 1.week.ago, ends_at: 1.week.from_now)
      create(:billing_period, starts_at: 2.months.ago, ends_at: 1.month.ago)

      expect(described_class.for_date(Time.current)).to eq([ period ])
    end
  end

  describe "#total_tokens" do
    it "sums input and output tokens" do
      period = build(:billing_period, total_input_tokens: 1000, total_output_tokens: 500)
      expect(period.total_tokens).to eq(1500)
    end
  end

  describe "#close!" do
    it "sets status to closed" do
      period = create(:billing_period, status: "open")
      period.close!
      expect(period.reload.status).to eq("closed")
    end
  end

  describe "status predicates" do
    it "#open? returns true for open status" do
      expect(build(:billing_period, status: "open")).to be_open
    end

    it "#closed? returns true for closed status" do
      expect(build(:billing_period, status: "closed")).to be_closed
    end

    it "#invoiced? returns true for invoiced status" do
      expect(build(:billing_period, status: "invoiced")).to be_invoiced
    end
  end
end
