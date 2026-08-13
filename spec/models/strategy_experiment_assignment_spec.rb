# frozen_string_literal: true

require "rails_helper"

RSpec.describe StrategyExperimentAssignment do
  describe "associations" do
    it { is_expected.to belong_to(:strategy_experiment) }
    it { is_expected.to belong_to(:strategy_experiment_variant) }
    it { is_expected.to belong_to(:agent_run) }
  end

  describe "validations" do
    it "rejects a variant from a different experiment" do
      experiment_a = create(:strategy_experiment)
      experiment_b = create(:strategy_experiment)
      variant_b = create(:strategy_experiment_variant, strategy_experiment: experiment_b)

      assignment = build(:strategy_experiment_assignment,
        strategy_experiment: experiment_a,
        strategy_experiment_variant: variant_b)

      expect(assignment).not_to be_valid
      expect(assignment.errors[:strategy_experiment_variant]).to be_present
    end
  end
end
