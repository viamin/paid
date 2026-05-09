# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScalingExperiment do
  describe "validations" do
    subject(:scaling_experiment) { build(:scaling_experiment) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:hypothesis) }
    it { is_expected.to validate_inclusion_of(:dimension).in_array(described_class::DIMENSIONS) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
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
end
