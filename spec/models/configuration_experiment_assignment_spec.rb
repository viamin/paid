# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationExperimentAssignment do
  it { is_expected.to belong_to(:configuration_experiment) }
  it { is_expected.to belong_to(:configuration_experiment_variant) }
  it { is_expected.to belong_to(:agent_run) }

  it "requires the variant to belong to the experiment" do
    experiment = create(:configuration_experiment)
    other_variant = create(:configuration_experiment_variant)
    assignment = build(:configuration_experiment_assignment,
      configuration_experiment: experiment,
      configuration_experiment_variant: other_variant)

    expect(assignment).not_to be_valid
    expect(assignment.errors[:configuration_experiment_variant]).to include("must belong to the same configuration experiment")
  end
end
