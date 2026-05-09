# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScalingExperiments::Create do
  describe ".call" do
    let(:project) { create(:project) }

    it "creates a draft experiment with safe defaults" do
      experiment = described_class.call(
        project: project,
        name: "Agent Count Scaling",
        hypothesis: "More agents improve success until returns flatten.",
        values_tested: [ 4, 1, 2, 2 ],
        control_value: 1
      )

      expect(experiment).to be_persisted
      expect(experiment.project).to eq(project)
      expect(experiment.status).to eq("draft")
      expect(experiment.values_tested).to eq([ 1, 2, 4 ])
      expect(experiment.context_filter).to include("min_task_count" => 2)
    end
  end
end
