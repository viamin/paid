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

  describe "#cached_or_compute_summary", :no_db do
    let(:generated_at) { Time.zone.parse("2026-05-12 12:00:00 UTC") }
    let(:legacy_cached_summary) do
      {
        "status" => "ready_for_analysis",
        "dimension" => "parallelism",
        "values" => [
          {
            "assigned_value" => 2,
            "sample_count" => 6,
            "success_rate" => 0.8,
            "avg_duration_seconds" => 120.0
          }
        ]
      }
    end

    it "hydrates legacy cached summaries with a generated_at timestamp from the record" do
      experiment, persisted_summary = build_legacy_cached_summary_proxy

      summary = experiment.cached_or_compute_summary

      expect(summary["generated_at"]).to eq(generated_at.iso8601)
      expect(persisted_summary.call).to include("generated_at" => generated_at.iso8601)
    end

    def build_legacy_cached_summary_proxy
      klass = described_class
      persisted_summary = nil
      summary_payload = legacy_cached_summary
      timestamp = generated_at
      experiment = klass.allocate
      bind_cached_summary_methods(experiment, klass)
      experiment.define_singleton_method(:cached_summary) { summary_payload }
      experiment.define_singleton_method(:summary_samples_key) { "1:0,2:0" }
      experiment.define_singleton_method(:updated_at) { timestamp }
      experiment.define_singleton_method(:samples_key) { "1:0,2:0" }
      experiment.define_singleton_method(:update_columns) { |attrs| persisted_summary = attrs[:cached_summary] }
      [ experiment, -> { persisted_summary } ]
    end

    def bind_cached_summary_methods(experiment, klass)
      %i[
        cached_or_compute_summary
        cached_summary_with_generated_at
        persist_cached_summary_generated_at!
        generated_summary_timestamp_missing?
        generated_summary_payload?
        cached_summary_fallback_timestamp
      ].each do |method_name|
        experiment.define_singleton_method(method_name) do |*args, **kwargs, &block|
          klass.instance_method(method_name).bind_call(self, *args, **kwargs, &block)
        end
      end
    end
  end
end
