# frozen_string_literal: true

require "rails_helper"

# @spec STAGED-CLOSEOUT-ADOPTION-015
RSpec.describe CloseoutVerifications::RetryPolicy do
  let(:project) { create(:project, auto_pick_enabled: true) }
  let(:owner) { create(:user, :owner, account: project.account) }
  let(:issue) { create(:issue, project:) }
  let(:criterion) { "Retryable live observation" }

  around do |example|
    previous = ENV["PAID_DEPLOYED_REVISION"]
    ENV["PAID_DEPLOYED_REVISION"] = "fixture-reviewed-retry-target"
    example.run
  ensure
    ENV["PAID_DEPLOYED_REVISION"] = previous
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
      environment_class: Rails.env.to_s, freshness_seconds: 60, retry_policy: { "max_attempts" => 3 } })
  end

  def admit
    CloseoutVerifications::AdmitLiveTarget.call(project:).runs
  end

  def stub_pause_label_writes
    url = "https://api.github.com/repos/#{project.full_name}/issues/#{issue.github_number}/labels"
    stub_request(:post, url).to_return(status: 200, body: "[]")
    stub_request(:delete, "#{url}/paid-paused").to_return(status: 204)
  end

  it "admits no verification after the source issue is closed" do
    issue.update!(github_state: "closed")
    expect(admit).to be_empty
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-016
  it "admits no verification while the source issue is paused" do
    stub_pause_label_writes
    issue.update!(paused: true)
    expect(admit).to be_empty
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-016
  it "defers a source-paused claim and resumes the same attempt after unpausing" do
    stub_pause_label_writes
    run = admit.sole
    issue.update!(paused: true)
    expect { CloseoutVerificationJob.perform_now(run.id) }.not_to change(TrustedMeasurementAttempt, :count)
    expect(run.reload.status).to eq("queued")
    issue.update!(paused: false)
    CloseoutVerificationJob.perform_now(run.id)
    expect(run.reload.status).to eq("completed")
    expect(AgentRun.where(issue:, goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL).count).to eq(1)
  end

  it "does not read for a source closed after admission" do
    run = admit.sole
    issue.update!(github_state: "closed")
    expect { CloseoutVerificationJob.perform_now(run.id) }.not_to change(TrustedMeasurementAttempt, :count)
  end

  it "collects a new expired generation without modifying the old terminal receipt" do
    first = admit.sole
    CloseoutVerificationJob.perform_now(first.id)
    receipt = first.reload.verification_result.deep_dup
    completed = first.completed_at
    expect(admit).to be_empty
    travel 61.seconds do
      second = admit.sole
      expect(second.id).not_to eq(first.id)
      CloseoutVerificationJob.perform_now(second.id)
      expect(admit).to be_empty
    end
    expect(first.reload.verification_result).to eq(receipt)
    expect(first.completed_at).to eq(completed)
  end

  it "stops at the reviewed total attempt limit" do
    3.times do
      run = admit.sole
      CloseoutVerificationJob.perform_now(run.id)
      travel 61.seconds
    end
    expect(admit).to be_empty
    expect(AgentRun.where(issue:, goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL).count).to eq(3)
  ensure
    travel_back
  end

  it "does not renew a cancelled identity" do
    run = admit.sole
    run.update!(status: "cancelled", completed_at: Time.current)
    travel 2.minutes do
      expect(admit).to be_empty
    end
  end

  it "enforces generation uniqueness in the database" do
    first = admit.sole
    CloseoutVerificationJob.perform_now(first.id)
    travel 61.seconds do
      second = admit.sole
      expect do
        AgentRun.transaction(requires_new: true) { second.dup.save! }
      end.to raise_error(ActiveRecord::RecordNotUnique, /live_closeout_verification_attempt_identity/)
      expect(admit).to be_empty
    end
  end

  it "does not recover retries after enrollment is disabled" do
    first = admit.sole
    CloseoutVerificationJob.perform_now(first.id)
    StagedCloseoutAdoption::Enroll.call(project:, actor: owner, enabled: false)
    travel 61.seconds do
      expect { CloseoutVerificationRetrySweepJob.perform_now }.not_to change(AgentRun, :count)
      expect(admit).to be_empty
    end
  end

  it "keeps the default retry policy at one total attempt" do
    expect(described_class.limit({})).to eq(1)
  end

  it "recovers an expired retry through the bounded sweep and deduplicates replay" do
    first = admit.sole
    CloseoutVerificationJob.perform_now(first.id)
    travel 61.seconds do
      CloseoutVerificationRetrySweepJob.perform_now
      CloseoutVerificationRetrySweepJob.perform_now
      runs = AgentRun.where(issue:, goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL)
      expect(runs.count).to eq(2)
      expect(runs.order(:id).last.closeout_verification_generation).to eq(1)
    end
  end

  it "refuses an unbounded reviewed allowance" do
    mapping = project.staged_closeout_mappings.approved.sole
    attributes = mapping.attributes.slice("criterion_key", "stage", "phase", "target_shape", "execution_path",
      "target_key", "environment_class", "freshness_seconds").merge("retry_policy" => { "max_attempts" => 100 })
    expect { StagedCloseoutAdoption::Mappings.approve(project:, actor: owner, issue:, attributes:) }
      .to raise_error(StagedCloseoutAdoption::Error, /one and three/)
  end

  it "admits the report-only audit for current staged evidence despite the ordinary PR-sync grace" do
    source_pr = create(:issue, :pull_request, project:, parent_issue: issue, github_number: 42,
      github_state: "closed", pr_review_phase: "merged", merged_commit_sha: "a" * 40)
    create(:agent_run, :completed, project:, issue:, goal: "create_pr", completed_at: Time.current,
      pull_request_number: 42, pull_request_url: source_pr.github_html_url, result_commit_sha: "a" * 40)
    run = admit.sole
    CloseoutVerificationJob.perform_now(run.id)

    requests = IssueContinuationRequest.where(issue:).where("evidence->>'continuation_mode' = 'acceptance_audit'")
    expect(requests.count).to eq(1)
    expect(Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(project)).not_to exist(id: issue.id)
  end
end
