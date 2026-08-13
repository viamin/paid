# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectBaseline do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
  end

  describe "validations" do
    subject { build(:project_baseline) }

    it { is_expected.to validate_presence_of(:metric_name) }
    it { is_expected.to validate_inclusion_of(:metric_name).in_array(described_class::METRIC_NAMES) }
    it { is_expected.to validate_uniqueness_of(:metric_name).scoped_to(:project_id) }
    it { is_expected.to validate_numericality_of(:sample_count).is_greater_than_or_equal_to(0) }
  end

  describe "METRIC_NAMES" do
    it "includes expected metrics" do
      expect(described_class::METRIC_NAMES).to contain_exactly(
        "tokens_total", "duration_seconds", "iterations", "cost_cents"
      )
    end
  end
end
