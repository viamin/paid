# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::CaptureApplicationLog do
  def verification_eligible_agent_run
    create(:agent_run, :running).tap { |agent_run| agent_run.project.update!(verification_enabled: true) }
  end

  # @spec OBSERVABILITY-APP-DIAGNOSTICS-004
  it "persists the bounded redacted log tail on the run" do
    agent_run = verification_eligible_agent_run

    described_class.call(agent_run:, content: "boot token=super-secret-value\n")

    expect(agent_run.reload.verification_result).to include(
      "app_log_tail" => /\[REDACTED/
    )
    expect(agent_run.verification_result["app_log_recorded_at"]).to be_present
  end

  # @spec OBSERVABILITY-APP-DIAGNOSTICS-004
  it "redacts active account credentials before persistence" do
    agent_run = verification_eligible_agent_run
    credential = create(:integration_credential, account: agent_run.project.account, secret: "stagingpassword")

    described_class.call(agent_run:, content: "upstream denied credential: #{credential.secret}")

    persisted_log = agent_run.reload.verification_result.fetch("app_log_tail")
    expect(persisted_log).to include("[REDACTED:known_secret]")
    expect(persisted_log).not_to include(credential.secret)
  end

  # @spec OBSERVABILITY-APP-DIAGNOSTICS-004
  it "does not overwrite a verification result finalized after the run was loaded" do
    agent_run = verification_eligible_agent_run
    stale_agent_run = AgentRun.find(agent_run.id)
    finalized_result = { "status" => "passed", "summary" => "Verification completed" }
    agent_run.update!(verification_result: finalized_result)
    agent_run.complete!

    described_class.call(agent_run: stale_agent_run, content: "application started")

    expect(agent_run.reload.verification_result).to eq(finalized_result)
  end

  # @spec OBSERVABILITY-APP-DIAGNOSTICS-004
  it "raises when the payload exceeds the bounded log byte cap" do
    agent_run = verification_eligible_agent_run

    expect {
      described_class.call(agent_run:, content: "x" * (described_class::MAX_LOG_BYTES + 1))
    }.to raise_error(AgentRuns::CaptureApplicationLog::TooLargeError)
    expect(agent_run.reload.verification_result).to be_blank
  end

  # @spec OBSERVABILITY-APP-DIAGNOSTICS-004
  it "bounds redacted content that expands beyond the log byte cap" do
    agent_run = verification_eligible_agent_run
    content = "a@b.co " * (described_class::MAX_LOG_BYTES / 7)

    described_class.call(agent_run:, content:)

    result = agent_run.reload.verification_result
    expect(result.fetch("app_log_tail").bytesize).to be <= described_class::MAX_LOG_BYTES
    expect(result).to include("app_log_truncated" => true)
  end

  # @spec OBSERVABILITY-APP-DIAGNOSTICS-004
  it "treats a blank payload as a no-capture and does not overwrite retained evidence" do
    agent_run = verification_eligible_agent_run
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
