# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScalingExperiments::SummarizeResults, :no_db do
  let(:outcome_metrics) do
    [
      { "key" => "success_rate", "primary" => true },
      { "key" => "duration_seconds", "primary" => false },
      { "key" => "total_cost_cents", "primary" => false },
      { "key" => "agent_launch_success_rate", "primary" => false },
      { "key" => "blocked_task_rate", "primary" => false }
    ]
  end

  it "excludes assignments with missing orchestration counts from aggregate rates" do
    assignments = [
      assignment_with_missing_orchestration_counts(2),
      assignment_with_recorded_orchestration_counts(2, launched: 4, succeeded: 3, blocked: 1, task_count: 4)
    ]

    summary = summarize(assignments)
    value_summary = summary.fetch("values").find { |value| value["assigned_value"] == 2 }

    expect(value_summary).to include(
      "agent_launch_success_rate" => 0.75,
      "blocked_task_rate" => 0.25,
      "success_rate_confidence_interval" => hash_including("sample_count" => 2, "confidence_level" => 0.95),
      "avg_duration_seconds_confidence_interval" => hash_including("sample_count" => 2, "confidence_level" => 0.95),
      "agent_launch_success_rate_confidence_interval" => hash_including("sample_count" => 4, "confidence_level" => 0.95),
      "blocked_task_rate_confidence_interval" => hash_including("sample_count" => 4, "confidence_level" => 0.95)
    )
  end

  it "derives orchestration rate intervals from aggregated underlying counts" do
    assignments = [
      assignment_with_recorded_orchestration_counts(2, launched: 1, succeeded: 1, blocked: 0, task_count: 1),
      assignment_with_recorded_orchestration_counts(2, launched: 100, succeeded: 90, blocked: 10, task_count: 100)
    ]

    value_summary = summarize(assignments).fetch("values").find { |value| value["assigned_value"] == 2 }

    expect(value_summary["agent_launch_success_rate"]).to eq(0.901)
    expect(value_summary.dig("agent_launch_success_rate_confidence_interval", "mean")).to eq(0.901)
    expect(value_summary.dig("agent_launch_success_rate_confidence_interval", "sample_count")).to eq(101)
    expect(value_summary["blocked_task_rate"]).to eq(0.099)
    expect(value_summary.dig("blocked_task_rate_confidence_interval", "mean")).to eq(0.099)
    expect(value_summary.dig("blocked_task_rate_confidence_interval", "sample_count")).to eq(101)
  end

  it "emits confidence intervals for every supported primary metric" do
    assignments = [
      build_assignment(2, observation: build_observation(2), outcome_summary: { "cohort_label" => "agent_count-2__tasks-2-3" })
    ]

    value_summary = summarize(assignments).fetch("values").first

    expect(value_summary["avg_parallelism_observed_confidence_interval"]).to include(
      "confidence_level" => 0.95
    )
  end

  it "adds scaling-law analysis and allocator guidance to the cached summary" do
    assignments = [
      build_assignment(1,
        observation: build_observation(1, success: false, duration: 300, cost: 100),
        outcome_summary: { "cohort_label" => "agent_count-1__tasks-2-3" }),
      build_assignment(2,
        observation: build_observation(2, duration: 180, cost: 160),
        outcome_summary: { "cohort_label" => "agent_count-2__tasks-2-3", "avg_quality_score" => 0.9, "quality_metric_sample_count" => 1 }),
      build_assignment(2,
        observation: build_observation(2, duration: 175, cost: 165),
        outcome_summary: { "cohort_label" => "agent_count-2__tasks-2-3", "avg_quality_score" => 0.95, "quality_metric_sample_count" => 1 })
    ]

    summary = summarize(assignments)

    expect(summary.dig("scaling_law", "status")).to eq("ready")
    expect(summary.dig("scaling_law", "recommended_value")).to eq(2)
    expect(summary.dig("allocator_decision", "requested_agent_count")).to eq(2)
    expect(summary.dig("scaling_law", "allocator_decision", "efficiency_gain_vs_control")).to be >= 0.10
    expect(summary.dig("sample_threshold_review", "rdr_target_min_samples_per_value")).to eq(30)
    expect(summary.fetch("simplifications")).not_to be_empty
  end

  def summarize(assignments)
    described_class.call(scaling_experiment: build_experiment(assignments))
  end

  def build_experiment(assignments)
    Struct.new(
      :dimension,
      :control_value,
      :outcome_metrics,
      :cohort_settings,
      :min_samples_per_value,
      :values_tested,
      :scaling_experiment_assignments,
      keyword_init: true
    ) do
      def sufficient_samples?
        true
      end

      def samples_key
        "1:1,2:2"
      end
    end.new(
      dimension: "agent_count",
      control_value: 1,
      outcome_metrics: outcome_metrics,
      cohort_settings: {
        "assignment_strategy" => "balanced_underfilled",
        "cadence" => "continuous",
        "label_template" => "%<dimension>s-%<value>s__%<task_bucket>s"
      },
      min_samples_per_value: 2,
      values_tested: [ 1, 2 ],
      scaling_experiment_assignments: build_assignment_relation(assignments)
    )
  end

  def build_assignment_relation(assignments)
    Struct.new(:assignments, keyword_init: true) do
      def recorded
        self
      end

      def includes(*)
        self
      end

      def to_a
        assignments
      end
    end.new(assignments: assignments)
  end

  def build_assignment(assigned_value, observation:, outcome_summary:)
    Struct.new(:assigned_value, :scaling_observation, :outcome_summary, keyword_init: true).new(
      assigned_value: assigned_value,
      scaling_observation: observation,
      outcome_summary: outcome_summary
    )
  end

  def assignment_with_missing_orchestration_counts(assigned_value)
    build_assignment(
      assigned_value,
      observation: build_observation(assigned_value, launched: 0, succeeded: 0, blocked: 0, task_count: 0),
      outcome_summary: { "cohort_label" => "agent_count-#{assigned_value}__tasks-#{assigned_value}-3" }
    )
  end

  def assignment_with_recorded_orchestration_counts(assigned_value, launched:, succeeded:, blocked:, task_count:)
    build_assignment(
      assigned_value,
      observation: build_observation(
        assigned_value,
        launched: launched,
        succeeded: succeeded,
        blocked: blocked,
        task_count: task_count
      ),
      outcome_summary: {
        "cohort_label" => "agent_count-#{assigned_value}__tasks-#{task_count}",
        "agent_count_launched" => launched,
        "agent_count_succeeded" => succeeded,
        "agent_count_blocked" => blocked
      }
    )
  end

  def build_observation(agent_count, success: true, duration: 120, cost: 300, launched: agent_count, succeeded: launched, blocked: 0, task_count: agent_count)
    Struct.new(
      :success,
      :total_iterations,
      :max_iterations,
      :duration_seconds,
      :total_cost_cents,
      :parallelism_observed,
      :agent_count_launched,
      :agent_count_succeeded,
      :status,
      :parallel_execution,
      :parallelism_planned,
      :agent_count_planned,
      :agent_count_blocked,
      :task_count,
      keyword_init: true
    ).new(
      success: success,
      total_iterations: 3,
      max_iterations: 2,
      duration_seconds: duration,
      total_cost_cents: cost,
      parallelism_observed: agent_count,
      agent_count_launched: launched,
      agent_count_succeeded: succeeded,
      status: "completed",
      parallel_execution: true,
      parallelism_planned: agent_count,
      agent_count_planned: agent_count,
      agent_count_blocked: blocked,
      task_count: task_count
    )
  end
end
