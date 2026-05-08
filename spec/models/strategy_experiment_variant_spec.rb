# frozen_string_literal: true

require "rails_helper"

RSpec.describe StrategyExperimentVariant do
  describe "validations" do
    it { is_expected.to validate_presence_of(:strategy_config) }
    it { is_expected.to belong_to(:strategy_experiment) }
    it { is_expected.to have_many(:strategy_experiment_assignments).dependent(:destroy) }
  end

  describe "#parsed_config" do
    it "returns the parsed JSON config" do
      variant = build(:strategy_experiment_variant, strategy_config: JSON.generate("version" => "v2"))

      expect(variant.parsed_config).to eq("version" => "v2")
    end
  end

  describe "#record_quality_score!" do
    it "atomically updates the aggregate scores" do
      variant = create(:strategy_experiment_variant)

      variant.record_quality_score!(0.8)

      expect(variant.reload.sample_count).to eq(1)
      expect(variant.avg_quality_score.to_f).to eq(0.8)
    end

    it "rejects scores outside 0..1" do
      variant = create(:strategy_experiment_variant)

      expect { variant.record_quality_score!(1.5) }.to raise_error(ArgumentError)
    end
  end
end
