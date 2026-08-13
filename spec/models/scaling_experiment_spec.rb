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

    it "rejects unsupported independent variables" do
      scaling_experiment.independent_variables = [
        {
          "key" => "repo_size",
          "role" => "context",
          "source" => "project.metadata"
        },
        {
          "key" => "agent_count",
          "role" => "primary",
          "values" => [ 1, 2, 4 ],
          "control_value" => 1
        }
      ]

      expect(scaling_experiment).not_to be_valid
      expect(scaling_experiment.errors[:independent_variables])
        .to include("contains unsupported keys: repo_size")
    end

    it "requires supported control-definition fields and cohort settings" do
      scaling_experiment.control_definition = { "comparison_method" => "cross_project" }
      scaling_experiment.cohort_settings = { "assignment_strategy" => "random" }

      expect(scaling_experiment).not_to be_valid
      expect(scaling_experiment.errors[:control_definition])
        .to include("must include a supported comparison_method")
      expect(scaling_experiment.errors[:control_definition])
        .to include("must include fairness_conditions as a non-empty array")
      expect(scaling_experiment.errors[:cohort_settings])
        .to include("must include a supported assignment_strategy")
      expect(scaling_experiment.errors[:cohort_settings])
        .to include("must include at least one task_count_bucket")
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

  describe "#eligible_values" do
    it "caps agent_count values by task count" do
      experiment = build(:scaling_experiment, dimension: "agent_count", values_tested: [ 1, 2, 4 ])

      expect(experiment.eligible_values(task_count: 2)).to eq([ 1, 2 ])
    end

    it "keeps iteration_count values independent of task count" do
      experiment = build(:scaling_experiment, dimension: "iteration_count", values_tested: [ 1, 2, 4 ])

      expect(experiment.eligible_values(task_count: 2)).to eq([ 1, 2, 4 ])
    end
  end

  describe "#cohort_label" do
    it "formats the configured task bucket into a stable cohort label" do
      experiment = build(:scaling_experiment)

      expect(experiment.cohort_label(task_count: 5, assigned_value: 2)).to eq("agent_count-2__tasks-4-6")
    end
  end

  describe "#control_cohort_label" do
    it "formats the control arm label for the same task bucket" do
      experiment = build(:scaling_experiment)

      expect(experiment.control_cohort_label(task_count: 5)).to eq("agent_count-1__tasks-4-6")
    end
  end
end
