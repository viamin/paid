# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTestVariant do
  describe "associations" do
    it { is_expected.to belong_to(:ab_test) }
    it { is_expected.to belong_to(:prompt_version) }
    it { is_expected.to have_many(:ab_test_assignments).dependent(:destroy) }
  end

  describe "#record_quality_score!" do
    it "increments sample_count and updates averages" do
      variant = create(:ab_test_variant, sample_count: 0, total_quality_score: 0)

      variant.record_quality_score!(0.8)
      expect(variant.sample_count).to eq(1)
      expect(variant.avg_quality_score.to_f).to eq(0.8)

      variant.record_quality_score!(0.6)
      expect(variant.sample_count).to eq(2)
      expect(variant.avg_quality_score.to_f).to eq(0.7)
    end
  end
end
