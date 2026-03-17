# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTestVariant do
  describe "validations" do
    subject { build(:ab_test_variant) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_uniqueness_of(:name).scoped_to(:ab_test_id) }
  end

  describe "associations" do
    it { is_expected.to belong_to(:ab_test) }
    it { is_expected.to belong_to(:prompt_version) }
    it { is_expected.to have_many(:assignments).class_name("AbTestAssignment").dependent(:destroy) }
  end

  describe "#record_quality_score!" do
    let(:variant) { create(:ab_test_variant, sample_count: 0, total_quality_score: 0.0, avg_quality_score: nil) }

    it "increments sample_count and updates scores" do
      variant.record_quality_score!(0.8)

      expect(variant.sample_count).to eq(1)
      expect(variant.total_quality_score).to eq(0.8)
      expect(variant.avg_quality_score).to eq(0.8)
    end

    it "correctly computes average over multiple calls" do
      variant.record_quality_score!(0.6)
      variant.record_quality_score!(1.0)

      expect(variant.sample_count).to eq(2)
      expect(variant.total_quality_score).to eq(1.6)
      expect(variant.avg_quality_score).to eq(0.8)
    end

    it "does nothing when score is nil" do
      expect { variant.record_quality_score!(nil) }.not_to change { variant.reload.sample_count }
    end
  end
end
