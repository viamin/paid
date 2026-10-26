# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrerequisiteValidationJob do
  let(:execution_result_class) do
    Struct.new(:ok, :values, keyword_init: true) do
      def success? = ok
      def [](key) = values.fetch(key)
    end
  end

  # @spec PREREQUISITE-VALIDATION-002
  it "records a failed isolated command and still cleans up its environment" do
    metadata = { "prerequisite_validation" => { "native_analyzer" => { "command" => "probe --version" } } }
    run = instance_double(AgentRun, status: "queued", external_metadata: metadata,
      authority_grants: {}, base_commit_sha: "abc123", worktree_path: nil, tool_sidecar_endpoints: [])
    result = execution_result_class.new(ok: false, values: { stdout: "out", stderr: "err", exit_code: 3 })
    allow(AgentRun).to receive(:find).with(123).and_return(run)
    allow(run).to receive(:update!) { |attributes| metadata.replace(attributes.fetch(:external_metadata)) if attributes[:external_metadata] }
    allow(run).to receive(:provision_execution_environment)
    allow(run).to receive(:execute_in_execution_environment).and_return(result)
    allow(run).to receive(:fail!)
    allow(run).to receive(:cleanup_execution_environment)

    described_class.perform_now(123)

    expect(run).to have_received(:execute_in_execution_environment).with("probe --version", timeout: 120, stream: false)
    expect(run).to have_received(:fail!).with(error: "Prerequisite validation command failed (exit 3).")
    expect(run).to have_received(:cleanup_execution_environment).with(force: true)
    expect(metadata.dig("prerequisite_validation", "result")).to include("stdout" => "out", "stderr" => "err", "exit_status" => 3)
    expect(metadata.dig("prerequisite_validation", "cleanup", "completed_at")).to be_present
  end
end
