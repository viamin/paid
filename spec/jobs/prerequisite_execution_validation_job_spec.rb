# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrerequisiteExecutionValidationJob do
  describe "#perform" do
    it "records a disabled sidecar rollout as unavailable without provisioning" do
      # @spec PARTIAL-CLOSEOUT-030
      run = instance_double(AgentRun,
        id: 42, status: "queued", project: instance_double(Project),
        external_metadata: { "prerequisite_execution_validation" => { "issue_id" => 9, "requested_tool_name" => "debride" } },
        verification_result: {}, tool_sidecar_snapshot: [], tool_sidecar_endpoints: [],
        runner_handle: nil, base_commit_sha: nil)
      allow(AgentRun).to receive(:find).with(42).and_return(run)
      allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, project: run.project).and_return(false)
      allow(run).to receive(:update!)
      allow(run).to receive(:provision_execution_environment)
      allow(run).to receive(:cleanup_execution_environment)
      allow(run).to receive(:reload).and_return(run)

      described_class.new.perform(42)

      expect(run).not_to have_received(:provision_execution_environment)
      expect(run).to have_received(:update!).with(hash_including(status: "failed", verification_result: hash_including(
        "prerequisite_execution_validation" => hash_including("outcome" => "unavailable")
      ))).at_least(:once)
    end
  end
end
