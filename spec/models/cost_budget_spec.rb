# frozen_string_literal: true

require "rails_helper"

RSpec.describe CostBudget do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
  end

  describe "validations" do
    subject { build(:cost_budget) }

    it { is_expected.to validate_presence_of(:budget_type) }
    it { is_expected.to validate_inclusion_of(:budget_type).in_array(described_class::BUDGET_TYPES) }
    it { is_expected.to validate_presence_of(:limit_cents) }
    it { is_expected.to validate_numericality_of(:limit_cents).is_greater_than(0) }
    it { is_expected.to validate_numericality_of(:current_usage_cents).is_greater_than_or_equal_to(0) }

    it "validates limit_dollars is greater than 0 when present" do
      budget = build(:cost_budget, limit_dollars: "0")
      budget.valid?

      expect(budget.errors[:limit_dollars]).to include("must be greater than 0")
      expect(budget.errors[:limit_cents]).to be_empty
    end

    it "validates limit_dollars rejects negative values" do
      budget = build(:cost_budget, limit_dollars: "-5")
      budget.valid?

      expect(budget.errors[:limit_dollars]).to include("must be greater than 0")
    end

    it { is_expected.to validate_numericality_of(:alert_threshold_percent).is_greater_than(0) }

    it "enforces uniqueness of budget_type per project" do
      project = create(:project)
      create(:cost_budget, project: project, budget_type: "monthly")
      duplicate = build(:cost_budget, project: project, budget_type: "monthly")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:budget_type]).to include("has already been taken")
    end
  end

  describe "#exceeded?" do
    it "returns true when usage meets limit" do
      budget = build(:cost_budget, limit_cents: 1000, current_usage_cents: 1000)
      expect(budget).to be_exceeded
    end

    it "returns true when usage exceeds limit" do
      budget = build(:cost_budget, limit_cents: 1000, current_usage_cents: 1500)
      expect(budget).to be_exceeded
    end

    it "returns false when under limit" do
      budget = build(:cost_budget, limit_cents: 1000, current_usage_cents: 500)
      expect(budget).not_to be_exceeded
    end
  end

  describe "#usage_percent" do
    it "calculates usage percentage" do
      budget = build(:cost_budget, limit_cents: 1000, current_usage_cents: 750)
      expect(budget.usage_percent).to eq(75.0)
    end

    it "returns 0 for zero limit" do
      budget = build(:cost_budget, limit_cents: 0, current_usage_cents: 0)
      budget.valid? # limit_cents: 0 would fail validation, but we test the method directly
      expect(budget.usage_percent).to eq(0)
    end
  end

  describe "#alert_threshold_reached?" do
    it "returns true when at or above threshold" do
      budget = build(:cost_budget, limit_cents: 1000, current_usage_cents: 800, alert_threshold_percent: 80)
      expect(budget).to be_alert_threshold_reached
    end

    it "returns false when below threshold" do
      budget = build(:cost_budget, limit_cents: 1000, current_usage_cents: 700, alert_threshold_percent: 80)
      expect(budget).not_to be_alert_threshold_reached
    end
  end

  describe "#remaining_cents" do
    it "returns remaining budget" do
      budget = build(:cost_budget, limit_cents: 1000, current_usage_cents: 300)
      expect(budget.remaining_cents).to eq(700)
    end

    it "returns 0 when exceeded" do
      budget = build(:cost_budget, limit_cents: 1000, current_usage_cents: 1500)
      expect(budget.remaining_cents).to eq(0)
    end
  end

  describe "#record_usage!" do
    it "increments current_usage_cents within current period" do
      budget = create(:cost_budget, current_usage_cents: 100, period_started_at: Time.current.beginning_of_month)
      budget.record_usage!(50)
      expect(budget.reload.current_usage_cents).to eq(150)
    end

    it "resets usage when period has rolled over for daily budgets" do
      budget = create(:cost_budget, :daily, current_usage_cents: 500, period_started_at: 2.days.ago)
      budget.record_usage!(50)
      budget.reload
      expect(budget.current_usage_cents).to eq(50)
      expect(budget.period_started_at).to be_within(1.second).of(Time.current.beginning_of_day)
    end

    it "resets usage when period has rolled over for monthly budgets" do
      budget = create(:cost_budget, current_usage_cents: 500, period_started_at: 2.months.ago)
      budget.record_usage!(50)
      budget.reload
      expect(budget.current_usage_cents).to eq(50)
      expect(budget.period_started_at).to be_within(1.second).of(Time.current.beginning_of_month)
    end

    it "does not reset per_run budgets" do
      budget = create(:cost_budget, :per_run, current_usage_cents: 100)
      budget.record_usage!(50)
      expect(budget.reload.current_usage_cents).to eq(150)
    end
  end

  describe "#reset_period!" do
    it "resets usage and alert state" do
      budget = create(:cost_budget, current_usage_cents: 5000, alert_sent_at: 1.day.ago)
      budget.reset_period!

      budget.reload
      expect(budget.current_usage_cents).to eq(0)
      expect(budget.alert_sent_at).to be_nil
      expect(budget.period_started_at).to be_within(1.second).of(Time.current)
    end
  end

  describe "#reset_for_new_run!" do
    it "resets per_run budgets" do
      budget = create(:cost_budget, :per_run, current_usage_cents: 500, alert_sent_at: 1.hour.ago)
      budget.reset_for_new_run!
      budget.reload

      expect(budget.current_usage_cents).to eq(0)
      expect(budget.alert_sent_at).to be_nil
    end

    it "does nothing for non-per_run budgets" do
      budget = create(:cost_budget, budget_type: "monthly", current_usage_cents: 500, period_started_at: Time.current.beginning_of_month)
      budget.reset_for_new_run!

      expect(budget.reload.current_usage_cents).to eq(500)
    end
  end

  describe "#rollover_if_period_expired!" do
    it "resets usage when daily period has expired" do
      budget = create(:cost_budget, :daily, current_usage_cents: 500, period_started_at: 2.days.ago)
      budget.rollover_if_period_expired!
      budget.reload

      expect(budget.current_usage_cents).to eq(0)
      expect(budget.period_started_at).to be_within(1.second).of(Time.current.beginning_of_day)
    end

    it "does nothing when daily period is current" do
      budget = create(:cost_budget, :daily, current_usage_cents: 500, period_started_at: Time.current.beginning_of_day)
      budget.rollover_if_period_expired!

      expect(budget.reload.current_usage_cents).to eq(500)
    end

    it "is a no-op for per_run budgets" do
      budget = create(:cost_budget, :per_run, current_usage_cents: 500)
      budget.rollover_if_period_expired!

      expect(budget.reload.current_usage_cents).to eq(500)
    end
  end

  describe "#alert_needed?" do
    it "returns true when threshold reached and no recent alert" do
      budget = build(:cost_budget, limit_cents: 1000, current_usage_cents: 850, alert_sent_at: nil)
      expect(budget).to be_alert_needed
    end

    it "returns false when threshold not reached" do
      budget = build(:cost_budget, limit_cents: 1000, current_usage_cents: 500, alert_sent_at: nil)
      expect(budget).not_to be_alert_needed
    end

    it "returns false when alert recently sent for monthly budget" do
      budget = build(:cost_budget, budget_type: "monthly", limit_cents: 1000, current_usage_cents: 850, alert_sent_at: 1.day.ago)
      expect(budget).not_to be_alert_needed
    end

    it "returns true when alert was sent long ago for monthly budget" do
      budget = build(:cost_budget, budget_type: "monthly", limit_cents: 1000, current_usage_cents: 850, alert_sent_at: 8.days.ago)
      expect(budget).to be_alert_needed
    end
  end
end
