# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScalingExperiments::SummarizeResults do
  let(:project) { create(:project) }
  let(:experiment) do
    create(:scaling_experiment,
      project: project,
      values_tested: [ 1, 2 ],
      cached_summary: {})
  end

  def create_recorded_assignment(outcome_summary)
    create(:scaling_experiment_assignment,
      scaling_experiment: experiment,
      project: project,
      assigned_value: 2,
      outcome_status: "recorded",
      outcome_summary: outcome_summary,
      scaling_observation: create(:scaling_observation, project: project, task_count: 2, parallelism_observed: 2, agent_count_launched: 2))
  end

  it "excludes missing rollout summary metrics from aggregate averages" do
    create_recorded_assignment("cohort_label" => "agent_count-2__tasks-2-3")
    create_recorded_assignment(
      "cohort_label" => "agent_count-2__tasks-2-3",
      "agent_launch_success_rate" => 0.75,
      "blocked_task_rate" => 0.25
    )

    summary = described_class.call(scaling_experiment: experiment)
    value_summary = summary.fetch("values").find { |value| value["assigned_value"] == 2 }

    expect(value_summary).to include(
      "agent_launch_success_rate" => 0.75,
      "blocked_task_rate" => 0.25
    )
  end

  it "stamps summaries with a generation timestamp for freshness checks" do
    summary = described_class.call(scaling_experiment: experiment)

    expect(Time.zone.parse(summary.fetch("generated_at"))).to be_within(5.seconds).of(Time.current)
  end
end
