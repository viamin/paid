# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationExperimentVariant do
  it { is_expected.to belong_to(:configuration_experiment) }
  it { is_expected.to have_many(:configuration_experiment_assignments).dependent(:destroy) }

  describe "#parsed_value" do
    it "returns the decoded JSON configuration value" do
      variant = build(:configuration_experiment_variant, config_value: JSON.generate([ "routes", "symbols" ]))

      expect(variant.parsed_value).to eq([ "routes", "symbols" ])
    end
  end

  describe "#record_quality_score!" do
    it "updates aggregate metrics" do
      variant = create(:configuration_experiment_variant, sample_count: 0, total_quality_score: 0)

      variant.record_quality_score!(0.8)
      variant.record_quality_score!(0.6)

      expect(variant.sample_count).to eq(2)
      expect(variant.avg_quality_score.to_f).to eq(0.7)
    end
  end
end
