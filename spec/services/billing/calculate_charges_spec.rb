# frozen_string_literal: true

require "rails_helper"

RSpec.describe Billing::CalculateCharges do
  let(:account) { create(:account) }

  describe "flat_rate billing model" do
    it "returns only a base rate item" do
      plan = create(:billing_plan, :flat_rate, account: account, base_rate_cents: 10_000)
      period = create(:billing_period, account: account, billing_plan: plan,
                       total_input_tokens: 500_000, total_output_tokens: 250_000, total_runs: 10)

      items = described_class.call(billing_period: period)

      expect(items.length).to eq(1)
      expect(items.first[:line_item_type]).to eq("base_rate")
      expect(items.first[:total_cents]).to eq(10_000)
    end
  end

  describe "per_token billing model" do
    let(:plan) do
      create(:billing_plan, account: account, billing_model: "per_token",
             per_token_rate_cents: 0.003, included_tokens: 1_000_000, base_rate_cents: 0)
    end

    it "shows included tokens and charges overage" do
      period = create(:billing_period, account: account, billing_plan: plan,
                       total_input_tokens: 1_500_000, total_output_tokens: 500_000)

      items = described_class.call(billing_period: period)

      included_item = items.find { |i| i[:line_item_type] == "token_usage" }
      overage_item = items.find { |i| i[:line_item_type] == "overage_tokens" }

      expect(included_item[:quantity]).to eq(1_000_000)
      expect(included_item[:total_cents]).to eq(0)
      expect(overage_item[:quantity]).to eq(1_000) # in 1K-token units
      expect(overage_item[:unit_price_cents]).to eq(3) # 0.003¢/token * 1000 = 3¢/1K
      expect(overage_item[:total_cents]).to eq(3000)
    end

    it "returns no overage when within included allowance" do
      period = create(:billing_period, account: account, billing_plan: plan,
                       total_input_tokens: 500_000, total_output_tokens: 200_000)

      items = described_class.call(billing_period: period)

      expect(items.none? { |i| i[:line_item_type] == "overage_tokens" }).to be true
    end

    it "accumulates fractional-cent token rates before rounding the total" do
      plan = create(:billing_plan, account: account, billing_model: "per_token",
                    per_token_rate_cents: 0.0004, included_tokens: 0, base_rate_cents: 0)
      period = create(:billing_period, account: account, billing_plan: plan,
                       total_input_tokens: 10_000, total_output_tokens: 0)

      items = described_class.call(billing_period: period)

      overage_item = items.find { |i| i[:line_item_type] == "overage_tokens" }
      expect(overage_item[:quantity]).to eq(10)
      expect(overage_item[:unit_price_cents]).to eq(0)
      expect(overage_item[:total_cents]).to eq(4)
      expect(overage_item[:description]).to include("0.4¢/1K")
    end
  end

  describe "per_run billing model" do
    let(:plan) do
      create(:billing_plan, :per_run, account: account,
             per_run_rate_cents: 500, included_runs: 10, base_rate_cents: 0)
    end

    it "charges for runs exceeding included allowance" do
      period = create(:billing_period, account: account, billing_plan: plan, total_runs: 15)

      items = described_class.call(billing_period: period)

      overage = items.find { |i| i[:line_item_type] == "overage_runs" }
      expect(overage[:quantity]).to eq(5)
      expect(overage[:total_cents]).to eq(2500)
    end
  end

  describe "per_project billing model" do
    let(:plan) do
      create(:billing_plan, :per_project, account: account,
             per_project_rate_cents: 5_000, included_projects: 3, base_rate_cents: 0)
    end

    it "charges for projects exceeding included allowance" do
      period = create(:billing_period, account: account, billing_plan: plan,
                       metadata: { "project_count" => 5 })

      items = described_class.call(billing_period: period)

      project_items = items.select { |i| i[:line_item_type] == "project_usage" }
      included = project_items.find { |i| i[:total_cents] == 0 }
      overage = project_items.find { |i| i[:total_cents] > 0 }

      expect(included[:quantity]).to eq(3)
      expect(overage[:quantity]).to eq(2)
      expect(overage[:total_cents]).to eq(10_000)
    end
  end

  describe "base rate with usage charges" do
    it "includes both base rate and usage items" do
      plan = create(:billing_plan, account: account, billing_model: "per_token",
                    base_rate_cents: 5_000, per_token_rate_cents: 0.003,
                    included_tokens: 0)
      period = create(:billing_period, account: account, billing_plan: plan,
                       total_input_tokens: 1_000_000, total_output_tokens: 0)

      items = described_class.call(billing_period: period)

      base = items.find { |i| i[:line_item_type] == "base_rate" }
      expect(base[:total_cents]).to eq(5_000)
      expect(items.length).to eq(2)
    end
  end
end
