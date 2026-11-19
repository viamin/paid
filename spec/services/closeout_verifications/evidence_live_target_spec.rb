# frozen_string_literal: true

require "rails_helper"

RSpec.describe CloseoutVerifications::Evidence do
  let(:project) { create(:project) }
  let(:maintainer) { create(:user, :owner, account: project.account) }
  let(:issue) { create(:issue, project:, body: "## Acceptance\n- Live measurement") }
  let(:revision) { "fixture-live-target-1" }
  let(:check_key) { "agent_planning_hold_reconciliation_closed_count" }
  let(:result) { { "active_closed_issue_count" => 0, "target" => 0 } }
  let(:mapping) do
    StagedCloseoutAdoption::Mappings.approve(project:, actor: maintainer, issue:, attributes: {
      criterion_key: "Live measurement", stage: "live_environment", phase: "operations",
      target_shape: "live_signal", execution_path: "trusted_measurement", target_key: check_key,
      environment_class: Rails.env.to_s, freshness_seconds: 60
    })
  end

  around do |example|
    previous = ENV["PAID_DEPLOYED_REVISION"]
    ENV["PAID_DEPLOYED_REVISION"] = revision
    example.run
  ensure
    ENV["PAID_DEPLOYED_REVISION"] = previous
  end

  before do
    project.update!(created_by: maintainer)
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(automation_phase_settings: { "phases" => { "operations" => true } })
    StagedCloseoutAdoption::Enroll.call(project:, actor: maintainer, enabled: true)
    create(:agent_run, :completed, project:, issue:, goal: "analyze_issue",
      pull_request_number: nil, pull_request_url: nil, reconciliation: { "assessment" => {
        "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
        "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
        "criteria" => [ { "criterion" => "Live measurement", "state" => "unmet" } ], "gaps" => []
      } })
  end

  def terminal_receipt(status: "succeeded", measurement_result: result)
    reviewed = mapping
    run = CloseoutVerifications::AdmitLiveTarget.call(project:).runs.sole
    attempt = TrustedMeasurementAttempt.create!(project:, account: project.account, issue:,
      external_issue_number: issue.github_number, criterion_key: reviewed.criterion_key,
      check_key:, check_version: reviewed.target_version, deployed_revision: revision,
      status:, result: measurement_result, executed_at: Time.current,
      failure_reason: status == "failed" ? "fixture read failure" : nil)
    receipt = {
      "source_issue_id" => issue.id, "criterion" => reviewed.criterion_key,
      "mapping_id" => reviewed.id, "recipe_version" => reviewed.target_version,
      "recipe_digest" => reviewed.target_digest, "target_revision" => revision,
      "measurement_attempt_id" => attempt.id, "measurement_status" => attempt.status,
      "measurement_result" => attempt.result, "measurement_failure_reason" => attempt.failure_reason,
      "measurement_executed_at" => attempt.executed_at.utc.iso8601(6),
      "outcome" => status == "succeeded" ? "observed" : "failed", "recorded_at" => Time.current.iso8601,
      "environment" => { "mapping_environment_class" => Rails.env.to_s, "target_revision" => revision }
    }.compact
    run.update!(status: status == "succeeded" ? "completed" : "failed", completed_at: Time.current,
      closeout_measurement_attempt_id: attempt.id, verification_result: { "closeout_verification" => receipt })
    [ run, attempt ]
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  # @spec PARTIAL-CLOSEOUT-057
  it "projects a signal-bound receipt and measured values without requiring a source PR" do
    run, attempt = terminal_receipt

    record = described_class.records_for(issue).sole

    expect(record).to include("verification_run_id" => run.id, "current" => true,
      "stage" => "live_environment", "target_revision" => revision,
      "measurement_attempt_id" => attempt.id, "measurement_status" => "succeeded",
      "measurement_result" => result, "outcome" => "observed")
    expect(record).not_to have_key("satisfied")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "invalidates the primary source revision when the confirmed signal changes" do
    terminal_receipt
    previous = described_class.revision_for(issue)
    ENV["PAID_DEPLOYED_REVISION"] = "fixture-live-target-2"

    expect(described_class.records_for(issue).sole).to include("current" => false)
    expect(described_class.revision_for(issue)).not_to eq(previous)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "rejects a measurement link for another source issue" do
    run, attempt = terminal_receipt
    other_issue = create(:issue, project:)
    attempt.update!(issue: other_issue, external_issue_number: other_issue.github_number)

    expect(described_class.current_for_run?(run)).to be(false)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "rejects a mutable attempt that no longer matches its retained snapshot" do
    run, attempt = terminal_receipt
    attempt.update!(result: { "active_closed_issue_count" => 42, "target" => 0 })

    expect(described_class.current_for_run?(run)).to be(false)
    expect(described_class.records_for(issue).sole.fetch("measurement_result")).to eq(result)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "rejects a receipt with no primary measurement link" do
    run, = terminal_receipt
    run.update_column(:closeout_measurement_attempt_id, nil)

    expect(described_class.current_for_run?(run)).to be(false)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "retains an authoritative failed read as current failure evidence" do
    terminal_receipt(status: "failed", measurement_result: {})

    expect(described_class.records_for(issue).sole).to include("current" => true,
      "outcome" => "failed", "measurement_status" => "failed", "measurement_result" => {})
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "bounds measurement output and reports incomplete coverage" do
    run, = terminal_receipt(measurement_result: { "fixture_output" => "m" * 5_000 })

    record = described_class.records_for(issue).sole
    expect(record.fetch("measurement_result").to_json.bytesize).to be < 2_100
    expect(record.fetch("evidence_truncated")).to be(true)
    packet = PartialCloseouts::AuditEvidence.new(issue:, agent_run: run)
    packet.call
    expect(packet.coverage.fetch("complete")).to be(false)
  end
end
