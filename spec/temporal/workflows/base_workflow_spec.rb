# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::BaseWorkflow, :no_db do
  let(:workflow_class) do
    Class.new(described_class) do
      def execute(input)
        [
          feature_flag_enabled?(:explicit_pr_automation_decisions, project_id: input[:project_id]),
          feature_flag_enabled?(:explicit_pr_automation_decisions, project_id: input[:project_id])
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

  describe "#feature_flag_enabled?" do
    it "loads the workflow flag snapshot through an activity and memoizes it per project" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::LoadFeatureFlagsActivity, { project_id: 123 }, timeout: 10)
        .and_return(flags: { explicit_pr_automation_decisions: true }, project_missing: false)

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
end
