# frozen_string_literal: true

require "rails_helper"

# @spec LID-RUNS-003
RSpec.describe Lid::CoherenceCheck do
  subject(:service) { described_class.call(agent_run: agent_run, container_service: container_service, logger: logger) }

  let(:agent_run) do
    instance_double(
      AgentRun,
      id: 123,
      goal: goal,
      external_metadata: {},
      update!: true,
      log!: true
    )
  end
  let(:goal) { "create_pr" }
  let(:container_service) { instance_double(Containers::Provision, execute: nil) }
  let(:logger) { instance_double(Logger, warn: true) }

  it "stores a parsed failed report in external_metadata" do
    output = <<~REPORT
      Reverse orphans (1) — @spec cites a spec that doesn't exist:
      Untagged code files (2) — behavior entry points with no @spec marker:

      Untagged test files (3) — tests with no @spec marker:
    REPORT
    allow(container_service).to receive(:execute)
      .and_return(Containers::Provision::Result.success(stdout: output, stderr: "", exit_code: 0))

    expect(agent_run).to receive(:update!).with(
      external_metadata: hash_including(
        "lid_coherence" => hash_including("status" => "failed", "untagged_test_files" => 3)
      )
    )

    result = service
    expect(result["status"]).to eq("failed")
  end

  it "skips non-LID repositories when the marker is emitted" do
    allow(container_service).to receive(:execute)
      .and_return(Containers::Provision::Result.success(stdout: "__PAID_LID_STATUS__ skipped", stderr: "", exit_code: 0))

    result = service

    expect(result["status"]).to eq("skipped")
    expect(result["summary_line"]).to include("skipped")
  end

  it "skips unsupported goals" do
    allow(agent_run).to receive(:goal).and_return("create_issue")

    result = service

    expect(result["status"]).to eq("skipped")
    expect(container_service).not_to have_received(:execute)
  end

  it "marks the check unavailable when the container command exits non-zero" do
    allow(container_service).to receive(:execute)
      .and_return(Containers::Provision::Result.failure(error: "boom", stdout: "", stderr: "stack trace", exit_code: 1))

    expect(agent_run).to receive(:update!).with(
      external_metadata: hash_including(
        "lid_coherence" => hash_including("status" => "unavailable")
      )
    )

    result = service

    expect(result["status"]).to eq("unavailable")
    expect(result["summary_line"]).to include("exit_code_1")
  end

  it "runs for lid_planning goals" do
    allow(agent_run).to receive(:goal).and_return("lid_planning")
    allow(container_service).to receive(:execute)
      .and_return(Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0))
    allow(Lid::CoherenceReport).to receive(:parse).with("").and_return(
      instance_double(Lid::CoherenceReport::Result, to_h: { "status" => "passed", "summary_line" => "ok" })
    )

    result = service

    expect(container_service).to have_received(:execute)
    expect(result["status"]).to eq("passed")
  end
end
