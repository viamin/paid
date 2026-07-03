# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::BaseWorkflow, :no_db do
  let(:workflow_class) do
    Class.new(described_class) do
      def execute(input)
        [
          feature_flag_enabled?(:test_flag, project_id: input[:project_id]),
          feature_flag_enabled?(:test_flag, project_id: input[:project_id])
        ]
      end
    end
  end

  let(:workflow) { workflow_class.new }

  describe "#decomposition_policy_metadata" do
    it "normalizes string-keyed top-level and nested provenance payloads" do
      result = workflow.send(
        :decomposition_policy_metadata,
        {
          "policy_source" => "top_level_source",
          "policy_metadata" => {
            "policy_source" => "coordination_policy",
            "policy_key" => "feature_decomposition",
            "coordination_policy_id" => 12,
            "coordination_policy_version_id" => 34,
            "coordination_policy_version" => 5
          }
        }
      )

      expect(result).to eq(
        policy_source: "coordination_policy",
        policy_key: "feature_decomposition",
        coordination_policy_id: 12,
        coordination_policy_version_id: 34,
        coordination_policy_version: 5
      )
    end
  end

  describe "#decomposition_policy_metadata_from_error" do
    it "extracts nested provenance from Temporal application error details" do
      error = Temporalio::Error::ApplicationError.new(
        "LLM failed",
        {
          policy_metadata: {
            policy_source: "coordination_policy",
            policy_key: "feature_decomposition",
            "coordination_policy_id" => 12,
            "coordination_policy_version_id" => 34,
            "coordination_policy_version" => 5
          }
        },
        type: "DecompositionFailed"
      )

      expect(workflow.send(:decomposition_policy_metadata_from_error, error)).to eq(
        policy_source: "coordination_policy",
        policy_key: "feature_decomposition",
        coordination_policy_id: 12,
        coordination_policy_version_id: 34,
        coordination_policy_version: 5
      )
    end
  end

  describe "#feature_flag_enabled?" do
    it "loads the workflow flag snapshot through an activity and memoizes it per project within one workflow run" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::LoadFeatureFlagsActivity, { project_id: 123 }, timeout: 10)
        .and_return(flags: { test_flag: true }, project_missing: false)

      expect(workflow.execute(project_id: 123)).to eq([ true, true ])
      expect(workflow).to have_received(:run_activity).once
    end

    it "returns false when the project disappears mid-workflow" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::LoadFeatureFlagsActivity, { project_id: 123 }, timeout: 10)
        .and_return(flags: {}, project_missing: true)

      expect(workflow.execute(project_id: 123)).to eq([ false, false ])
      expect(workflow).to have_received(:run_activity).once
    end
  end

  describe "#record_swallowed_non_critical_activity_failure" do
    let(:metric) { instance_double(Temporalio::Metric, record: nil) }
    let(:meter) { instance_double(Temporalio::Metric::Meter, create_metric: metric) }

    before do
      allow(Temporalio::Workflow).to receive(:metric_meter).and_return(meter)
    end

    def exhausted_activity_error(activity_type)
      Temporalio::Error::ActivityError.new(
        "activity failed",
        scheduled_event_id: 1,
        started_event_id: 2,
        identity: "worker-1",
        activity_type: activity_type,
        activity_id: "activity-1",
        retry_state: Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED
      )
    end

    it "records a workflow counter for exhausted retry failures" do
      error = exhausted_activity_error("CheckKnowledgeStalenessActivity")

      workflow.send(
        :record_swallowed_non_critical_activity_failure,
        project_id: 42,
        helper: "maybe_check_knowledge_staleness",
        error: error
      )

      expect(metric).to have_received(:record).with(
        1,
        additional_attributes: hash_including(
          "project_id" => "42",
          "helper" => "maybe_check_knowledge_staleness",
          "retry_state" => Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED.to_s
        )
      )
    end

    it "does not record for non-exhausted failures" do
      error = RuntimeError.new("boom")

      workflow.send(
        :record_swallowed_non_critical_activity_failure,
        project_id: 42,
        helper: "maybe_check_knowledge_staleness",
        error: error
      )

      expect(metric).not_to have_received(:record)
    end
  end

  describe "#run_cleanup_activity" do
    let(:detached_cancellation) { instance_double(Temporalio::Cancellation) }

    it "runs the activity with detached cancellation" do
      allow(Temporalio::Cancellation).to receive(:new).and_return([ detached_cancellation, -> { } ])
      allow(workflow).to receive(:run_activity).and_return({})

      workflow.send(:run_cleanup_activity, Activities::CleanupContainerActivity, { agent_run_id: 42 }, timeout: 30)

      expect(workflow).to have_received(:run_activity).with(
        Activities::CleanupContainerActivity,
        { agent_run_id: 42 },
        timeout: 30,
        cancellation: detached_cancellation
      )
    end
  end
end
