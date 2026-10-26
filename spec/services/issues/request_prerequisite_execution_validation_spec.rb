# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::RequestPrerequisiteExecutionValidation do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:, github_state: "open") }

  # @spec PREREQUISITE-EXECUTION-001
  it "queues one bounded report-only run and records its immutable contract" do
    result = described_class.call(issue:, actor: user)

    expect(result).to be_success
    expect(result.agent_run).to have_attributes(issue:, goal: "analyze_issue", status: "queued")
    expect(result.agent_run.custom_prompt).to include("technical prerequisite evidence")
    expect(result.agent_run.external_metadata.fetch("prerequisite_execution_validation")).to include(
      "issue_number" => issue.github_number,
      "artifact_contract" => include("stdout", "stderr", "exit_code", "cleanup"),
      "execution_capabilities" => include("available", "required", "tool_sidecar_rollout_authorized")
    )
    expect(ProcessRunQueueJob).to have_been_enqueued
  end

  # @spec PREREQUISITE-EXECUTION-004
  it "reuses an active validation for the same prerequisite instead of retrying unchanged work" do
    first = described_class.call(issue:, actor: user)
    second = described_class.call(issue:, actor: user)

    expect(second).to be_success
    expect(second.agent_run).to eq(first.agent_run)
    expect(issue.agent_runs.where(goal: "analyze_issue")).to contain_exactly(first.agent_run)
  end
end
