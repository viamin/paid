# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTests::Analyze do
  describe ".call" do
    let(:ab_test) { create(:ab_test, :running, :with_variants, min_sample_size: 2) }

    it "returns insufficient_data when min sample size not reached" do
      result = described_class.call(ab_test: ab_test)

      expect(result[:status]).to eq(:insufficient_data)
    end

    it "returns analysis when sample size is sufficient" do
      ab_test.variants.first.update!(sample_count: 5, avg_quality_score: 0.6, total_quality_score: 3.0)
      ab_test.variants.last.update!(sample_count: 5, avg_quality_score: 0.8, total_quality_score: 4.0)

      result = described_class.call(ab_test: ab_test)

      expect(result[:status]).to be_in([ :significant, :not_significant ])
      expect(result[:winner]).to be_present
      expect(result[:confidence]).to be_between(0.0, 1.0)
    end
  end
end
