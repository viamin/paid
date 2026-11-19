# frozen_string_literal: true

require "rails_helper"

# @spec STAGED-CLOSEOUT-ADOPTION-014
RSpec.describe Inbox::StagedCloseoutProgress do
  let(:project) { create(:project) }
  let(:owner) { create(:user, :owner, account: project.account) }
  let(:issue) { create(:issue, project:) }
  let(:criterion) { "Planning-hold observation" }

  around do |example|
    prior = ENV["PAID_DEPLOYED_REVISION"]
    ENV["PAID_DEPLOYED_REVISION"] = "fixture-live-progress-target"
    example.run
  ensure
    ENV["PAID_DEPLOYED_REVISION"] = prior
  end

  before do
    project.update!(created_by: owner)
    FeatureFlags.enable!(:automation_phases, project:)
    Automation::PhaseSettings::Update.call(project:, user: owner, params: { "phases" => { "operations" => true } })
    StagedCloseoutAdoption::Enroll.call(project:, actor: owner, enabled: true)
    create(:agent_run, :completed, project:, issue:, goal: "analyze_issue", result_commit_sha: nil,
      reconciliation: { "assessment" => {
        "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
        "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
        "criteria" => [ { "criterion" => criterion, "state" => "unmet" } ], "gaps" => []
      } })
    StagedCloseoutAdoption::Mappings.approve(project:, actor: owner, issue:, attributes: {
      criterion_key: criterion, stage: "live_environment", phase: "operations", target_shape: "live_signal",
      execution_path: "trusted_measurement", target_key: "agent_planning_hold_reconciliation_closed_count",
      environment_class: Rails.env.to_s, freshness_seconds: 60 })
  end

  def verification
    described_class.call(issue:).find { |milestone| milestone.id == "closeout_verification" }
  end

  it "shows queued identity and a waiting action without enqueuing work on read" do
    run = CloseoutVerifications::AdmitLiveTarget.call(project:).runs.sole
    expect { verification }.not_to change(AgentRun, :count)
    expect(verification.state).to eq("waiting")
    expect(verification.evidence.sole).to include(criterion:, run_state: "queued",
      revision: "fixture-live-progress-target", environment: "test")
    expect(verification.next_action).to include("Wait")
    expect(run.reload.status).to eq("queued")
    expect { verification }.not_to change(Notification, :count)
    expect(Inbox::Queue.call(user: owner, kind: Inbox::Queue::ACTION_REQUIRED_KIND)).to be_empty
  end

  it "distinguishes a running check from completed acceptance" do
    run = CloseoutVerifications::AdmitLiveTarget.call(project:).runs.sole
    run.update!(status: "running", started_at: Time.current)
    milestones = described_class.call(issue:)
    expect(verification.state).to eq("current")
    expect(milestones.find { |entry| entry.id == "acceptance_audit" }.state).not_to eq("complete")
    expect(milestones.find { |entry| entry.id == "source_closure" }.state).not_to eq("complete")
  end

  it "shows actual observed values and expiry separately from an unmet audit" do
    run = CloseoutVerifications::AdmitLiveTarget.call(project:).runs.sole
    CloseoutVerificationJob.perform_now(run.id)
    expect(verification.state).to eq("complete")
    expect(verification.evidence.sole).to include(outcome: "observed", environment: "test")
    expect(verification.evidence.sole.fetch(:expires_at)).to be_present
    expect(described_class.call(issue:).find { |entry| entry.id == "acceptance_audit" }.state).not_to eq("complete")
    travel 61.seconds do
      expect(verification.state).to eq("stale")
      expect(verification.next_action).to include("attempt allowance is exhausted")
      expect(verification.evidence.sole).to include(attempt: 1, maximum_attempts: 1, retry_reason: "retry_exhausted")
    end
  end

  it "does not mistake an old queued target for the latest completed verification" do
    old = CloseoutVerifications::AdmitLiveTarget.call(project:).runs.sole
    ENV["PAID_DEPLOYED_REVISION"] = "fixture-new-live-progress-target"
    current = CloseoutVerifications::AdmitLiveTarget.call(project:).runs.sole
    CloseoutVerificationJob.perform_now(current.id)

    expect(old.reload.status).to eq("queued")
    expect(verification.state).to eq("complete")
    expect(verification.evidence.sole).to include(run_state: "completed", revision: "fixture-new-live-progress-target")
    shared = Inbox::ProgressProjection.call(issue:).to_h
    expect(shared.fetch(:milestones).find { |entry| entry[:id] == "closeout_verification" }.fetch(:evidence))
      .to eq(verification.evidence)
  end

  it "shows a current failed read as blocked even when older targets are stale" do
    first = CloseoutVerifications::AdmitLiveTarget.call(project:).runs.sole
    CloseoutVerificationJob.perform_now(first.id)
    ENV["PAID_DEPLOYED_REVISION"] = "fixture-failed-live-progress-target"
    current = CloseoutVerifications::AdmitLiveTarget.call(project:).runs.sole
    # Inject below the registry so the reviewed check digest stays unchanged.
    fired = false
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
      next if fired || !event.payload[:sql].match?(/SELECT COUNT.*"notifications"/m)

      fired = true
      raise ActiveRecord::StatementInvalid, "fixture progress read failed"
    end
    expect { CloseoutVerificationJob.perform_now(current.id) }.to raise_error(StandardError, /fixture progress read failed/)

    expect(verification.state).to eq("blocked")
    expect(verification.evidence.sole.fetch(:outcome)).to eq("failed")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
