# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::CaptureApplicationLog do
  # @spec APP-DIAGNOSTICS-004
  it "persists the bounded redacted log tail on the run" do
    agent_run = create(:agent_run, :running)

    described_class.call(agent_run:, content: "boot token=super-secret-value\n")

    expect(agent_run.reload.verification_result).to include(
      "app_log_tail" => /\[REDACTED/
    )
    expect(agent_run.verification_result["app_log_recorded_at"]).to be_present
  end

  # @spec APP-DIAGNOSTICS-004
  it "preserves a verification result finalized after the run was loaded" do
    agent_run = create(:agent_run, :running)
    stale_agent_run = AgentRun.find(agent_run.id)
    finalized_result = { "status" => "passed", "summary" => "Verification completed" }
    agent_run.update!(verification_result: finalized_result)

    described_class.call(agent_run: stale_agent_run, content: "application started")

    expect(agent_run.reload.verification_result).to include(
      finalized_result.merge("app_log_tail" => "application started")
    )
  end

  # @spec APP-DIAGNOSTICS-004
  it "raises when the payload exceeds the bounded log byte cap" do
    agent_run = create(:agent_run, :running)

    expect {
      described_class.call(agent_run:, content: "x" * (described_class::MAX_LOG_BYTES + 1))
    }.to raise_error(AgentRuns::CaptureApplicationLog::TooLargeError)
    expect(agent_run.reload.verification_result).to be_blank
  end

  # @spec APP-DIAGNOSTICS-004
  it "treats a blank payload as a no-capture and does not overwrite retained evidence" do
    agent_run = create(:agent_run, :running)
    agent_run.update!(verification_result: {
      "app_log_tail" => "retained prior tail",
      "app_log_recorded_at" => "2026-10-21T00:00:00Z"
    })

    described_class.call(agent_run:, content: "")

    expect(agent_run.reload.verification_result).to include(
      "app_log_tail" => "retained prior tail",
      "app_log_recorded_at" => "2026-10-21T00:00:00Z"
    )
  end
end
