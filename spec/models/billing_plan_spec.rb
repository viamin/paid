# frozen_string_literal: true

require "rails_helper"

RSpec.describe BillingPlan do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to have_many(:billing_periods).dependent(:restrict_with_error) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(100) }
    it { is_expected.to validate_presence_of(:billing_model) }
    it { is_expected.to validate_inclusion_of(:billing_model).in_array(described_class::BILLING_MODELS) }
    it { is_expected.to validate_presence_of(:period_type) }
    it { is_expected.to validate_inclusion_of(:period_type).in_array(described_class::PERIOD_TYPES) }
    it { is_expected.to validate_numericality_of(:base_rate_cents).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:per_token_rate_cents).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:per_run_rate_cents).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:per_project_rate_cents).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:included_tokens).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:included_runs).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:included_projects).is_greater_than_or_equal_to(0) }
  end

  describe "scopes" do
    it ".active returns only active plans" do
      active = create(:billing_plan)
      create(:billing_plan, :inactive)

      expect(described_class.active).to eq([ active ])
    end
  end

  describe "billing model predicates" do
    it "#flat_rate? returns true for flat_rate model" do
      plan = build(:billing_plan, :flat_rate)
      expect(plan).to be_flat_rate
    end

    it "#per_token? returns true for per_token model" do
      plan = build(:billing_plan, billing_model: "per_token")
      expect(plan).to be_per_token
    end

    it "#per_run? returns true for per_run model" do
      plan = build(:billing_plan, :per_run)
      expect(plan).to be_per_run
    end

    it "#per_project? returns true for per_project model" do
      plan = build(:billing_plan, :per_project)
      expect(plan).to be_per_project
    end
  end
end
