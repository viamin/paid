# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScalingExperiments::Create do
  describe ".call" do
    let(:project) { create(:project) }
    let(:experiment) do
      described_class.call(
        project: project,
        name: "Agent Count Scaling",
        hypothesis: "More agents improve success until returns flatten.",
        values_tested: [ 4, 1, 2, 2 ],
        control_value: 1
      )
    end

    it "creates a draft experiment with normalized values and context defaults" do
      expect(experiment).to be_persisted
      expect(experiment.project).to eq(project)
      expect(experiment.status).to eq("draft")
      expect(experiment.values_tested).to eq([ 1, 2, 4 ])
      expect(experiment.context_filter).to include("min_task_count" => 2)
    end

    it "stores the experiment plan defaults for analysis and cohort scheduling" do
      expect(experiment.independent_variables).to include(
        hash_including("key" => "agent_count", "values" => [ 1, 2, 4 ], "control_value" => 1)
      )
      expect(experiment.outcome_metrics).to include(
        hash_including("key" => "success_rate", "primary" => true, "objective" => "maximize")
      )
      expect(experiment.control_definition).to include(
        "comparison_method" => "within_task_count_bucket",
        "guardrails" => array_including("respect_dependency_order")
      )
      expect(experiment.cohort_settings).to include(
        "assignment_strategy" => "balanced_underfilled",
        "label_template" => "%<dimension>s-%<value>s__%<task_bucket>s"
      )
      expect(experiment.outcome_metrics.map { |metric| metric["key"] }).to include(
        "agent_launch_success_rate",
        "blocked_task_rate"
      )
    end
  end
end
