# frozen_string_literal: true

require "rails_helper"

RSpec.describe CloseoutVerificationJob do
  let(:project) { create(:project, auto_pick_enabled: true) }
  let(:owner) { create(:user, :owner, account: project.account) }
  let(:issue) { create(:issue, project:, paid_state: "completed", body: "## Acceptance\n- Closed planning-hold notifications are cleared") }
  let(:criterion) { "Closed planning-hold notifications are cleared" }
  let(:check_key) { "agent_planning_hold_reconciliation_closed_count" }

  around do |example|
    previous = ENV["PAID_DEPLOYED_REVISION"]
    ENV["PAID_DEPLOYED_REVISION"] = "simulated-live-target-1"
    example.run
  ensure
    ENV["PAID_DEPLOYED_REVISION"] = previous
  end

  before do
    project.update!(created_by: owner)
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(automation_phase_settings: { "phases" => { "operations" => true, "release_deployment" => true } })
    StagedCloseoutAdoption::Enroll.call(project:, actor: owner, enabled: true)
    create(:issue, :pull_request, project:, parent_issue: issue, github_number: 42, github_state: "closed",
      pr_review_phase: "merged", merged_commit_sha: "a" * 40)
    create(:agent_run, :completed, project:, issue:, goal: "analyze_issue", pull_request_number: nil, pull_request_url: nil,
      reconciliation: { "assessment" => {
        "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
        "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
        "criteria" => [ { "criterion" => criterion, "state" => "unmet" } ], "gaps" => [] } })
    StagedCloseoutAdoption::Mappings.approve(project:, actor: owner, issue:, attributes: {
      criterion_key: criterion, stage: "live_environment", phase: "operations", target_shape: "live_signal",
      execution_path: "trusted_measurement", target_key: check_key, environment_class: Rails.env.to_s,
      freshness_seconds: 300 })
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "automatically admits a check and preserves matching measured evidence" do
    runs = AgentRun.where(project:, issue:, goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL)
    expect { LiveTargetCloseoutVerificationSweepJob.perform_now }
      .to change { runs.count }.from(0).to(1)
    run = runs.sole
    described_class.perform_now(run.id)
    attempt = TrustedMeasurementAttempt.where(project:, issue:, check_key:).sole

    expect(run.reload).to have_attributes(status: "completed", closeout_measurement_attempt: attempt)
    expect(attempt.deployed_revision).to eq("simulated-live-target-1")
    expect(attempt).to be_succeeded
    record = CloseoutVerifications::Evidence.records_for(issue).sole
    expect(record).to include("current" => true, "criterion_key" => criterion, "outcome" => "observed")
    expect(JSON.generate(record)).to include("simulated-live-target-1")
    expect(record).not_to have_key("satisfied")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "binds one report-only audit and preserves its terminal receipt on replay" do
    run = admit_live_run
    described_class.perform_now(run.id)
    attempt = run.reload.closeout_measurement_attempt
    audits = IssueContinuationRequest.where(issue:).where("evidence->>'continuation_mode' = ?", "acceptance_audit")
    expect(audits.count).to eq(1)
    expect(audits.sole.evidence.fetch("source_revision")).to eq(PartialCloseouts::Assessment.source_revision_for(issue))
    before_receipt = run.verification_result.deep_dup
    before_executed = attempt.executed_at

    LiveTargetCloseoutVerificationSweepJob.perform_now
    described_class.perform_now(run.id)

    expect(AgentRun.where(project:, issue:, goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL).count).to eq(1)
    expect(audits.count).to eq(1)
    expect(run.reload.verification_result).to eq(before_receipt)
    expect(attempt.reload.executed_at).to eq(before_executed)
  end

  def admit_live_run
    CloseoutVerifications::AdmitLiveTarget.call(project:).runs.sole
  end

  { goal: "create_pr", synthetic: false }.each do |attribute, value|
    # @spec STAGED-CLOSEOUT-ADOPTION-012
    it "rejects a live job with the wrong #{attribute} identity before any read" do
      run = admit_live_run
      run.update_column(attribute, value)

      expect { described_class.perform_now(run.id) }.not_to change(TrustedMeasurementAttempt, :count)
      expect(run.reload.status).to eq("failed")
      expect(run.verification_result.dig("closeout_verification", "outcome")).to eq("stale")
    end
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "defers a project paused after admission without reading live data" do
    run = admit_live_run
    project.pause!

    expect { described_class.perform_now(run.id) }.not_to change(TrustedMeasurementAttempt, :count)
    expect(run.reload.status).to eq("queued")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "defers a hard-stop budget without reading live data" do
    run = admit_live_run
    create(:cost_budget, :monthly, :hard_stop, project:, limit_cents: 100, current_usage_cents: 100)

    expect { described_class.perform_now(run.id) }.not_to change(TrustedMeasurementAttempt, :count)
    expect(run.reload.status).to eq("queued")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "does not read for authority made inactive after admission" do
    run = admit_live_run
    project.update!(active: false)

    expect { described_class.perform_now(run.id) }.not_to change(TrustedMeasurementAttempt, :count)
    expect(run.reload.status).not_to eq("completed")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "does not call a different declared environment the actual tested environment" do
    reviewed = project.staged_closeout_mappings.approved.find_by!(issue:)
    StagedCloseoutAdoption::Mappings.approve(project:, actor: owner, issue:, attributes: {
      criterion_key: criterion, stage: "live_environment", phase: "operations", target_shape: "live_signal",
      execution_path: "trusted_measurement", target_key: check_key,
      environment_class: "production", freshness_seconds: reviewed.freshness_seconds
    })

    outcome = CloseoutVerifications::AdmitLiveTarget.call(project:)

    expect(outcome.runs).to be_empty
    expect(outcome.reason).to eq("environment_class_mismatch")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "retains a read as stale when the trusted signal changes during collection" do
    run = admit_live_run
    observed = false
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
      if !observed && event.payload[:sql].match?(/SELECT COUNT.*\"notifications\"/m)
        observed = true
        ENV["PAID_DEPLOYED_REVISION"] = "simulated-live-target-2"
      end
    end

    described_class.perform_now(run.id)

    expect(observed).to be(true)
    expect(run.reload.status).to eq("failed")
    expect(run.verification_result.fetch("closeout_verification")).to include("outcome" => "stale")
    expect(CloseoutVerifications::Evidence.current_for_run?(run)).to be(false)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "retains an injected live-read failure and never reruns the terminal attempt" do
    run = admit_live_run
    fired = false
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
      next if fired || !event.payload[:sql].match?(/SELECT COUNT.*"notifications"/m)

      fired = true
      raise ActiveRecord::StatementInvalid, "fixture live read failed"
    end

    expect { described_class.perform_now(run.id) }.to raise_error(StandardError, /fixture live read failed/)
    attempt = run.reload.closeout_measurement_attempt
    expect(run.status).to eq("failed")
    expect(attempt).to be_failed
    expect(CloseoutVerifications::Evidence.records_for(issue).sole)
      .to include("current" => true, "outcome" => "failed", "measurement_status" => "failed")
    expect { described_class.perform_now(run.id) }.not_to change { attempt.reload.executed_at }
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "admits a changed confirmed target using unchanged approved intent without a manual audit" do
    run = admit_live_run
    described_class.perform_now(run.id)
    expect(PartialCloseouts::Assessment.call(issue)).to be_stale
    ENV["PAID_DEPLOYED_REVISION"] = "simulated-live-target-2"

    next_target = CloseoutVerifications::AdmitLiveTarget.call(project:)

    expect(next_target.runs).to contain_exactly(an_object_having_attributes(closeout_target_revision: "simulated-live-target-2"))
  end
end
