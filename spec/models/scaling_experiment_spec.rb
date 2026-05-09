# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScalingExperiment do
  describe "validations" do
    subject(:scaling_experiment) { build(:scaling_experiment) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:hypothesis) }
    it { is_expected.to validate_inclusion_of(:dimension).in_array(described_class::DIMENSIONS) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }

    it "requires one primary outcome metric" do
      scaling_experiment.outcome_metrics = [ { "key" => "success_rate", "primary" => false } ]

      expect(scaling_experiment).not_to be_valid
      expect(scaling_experiment.errors[:outcome_metrics]).to include("must include one primary metric")
    end

    it "requires the tested dimension to match the plan values" do
      scaling_experiment.independent_variables = [
        {
          "key" => "agent_count",
          "role" => "primary",
          "values" => [ 1, 2 ],
          "control_value" => 1
        }
      ]

      expect(scaling_experiment).not_to be_valid
      expect(scaling_experiment.errors[:independent_variables])
        .to include("must match values_tested and control_value for the tested dimension")
    end
  end

  describe ".active_for" do
    let(:project) { create(:project) }

    it "returns the running experiment when traffic and context match" do
      experiment = create(:scaling_experiment, project: project, traffic_percentage: 100)

      expect(
        described_class.active_for(project: project, dimension: "agent_count", workflow_id: "wf-1", task_count: 3)
      ).to eq(experiment)
    end

    it "returns nil when the workflow is excluded by task count" do
      create(:scaling_experiment, project: project, context_filter: { "min_task_count" => 4 })

      expect(
        described_class.active_for(project: project, dimension: "agent_count", workflow_id: "wf-1", task_count: 3)
      ).to be_nil
    end
  end

  describe "#cohort_label" do
    it "formats the configured task bucket into a stable cohort label" do
      experiment = build(:scaling_experiment)

      expect(experiment.cohort_label(task_count: 5, assigned_value: 2)).to eq("agent_count-2__tasks-4-6")
    end
  end
end
