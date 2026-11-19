# frozen_string_literal: true

require "rails_helper"

# @spec STAGED-CLOSEOUT-ADOPTION-015
# Actual profile/measurement/audit admission,
# simulated semantic completion and mocked external GitHub mutation.
RSpec.describe Issues::AutoResolveCloseout do
  let(:project) { create(:project, :with_github_installation, owner: "acme", repo: "live-closeout-fixture") }
  let(:owner) { create(:user, :owner, account: project.account) }
  let(:issue) { create(:issue, project:, github_state: "open", body: "## Acceptance\n- Closed planning-hold count reaches zero") }
  let(:criterion) { "Closed planning-hold count reaches zero" }
  let(:client) { instance_double(GithubClient) }

  let(:source_pr) do
    create(:issue, :pull_request, project:, parent_issue: issue, github_number: 42,
      github_state: "closed", pr_review_phase: "merged", merged_commit_sha: "a" * 40,
      body: "Tracks ##{issue.github_number}")
  end

  around do |example|
    previous = ENV["PAID_DEPLOYED_REVISION"]
    ENV["PAID_DEPLOYED_REVISION"] = "simulated-confirmed-live-target-5078"
    example.run
  ensure
    ENV["PAID_DEPLOYED_REVISION"] = previous
  end

  before do
    project.update!(created_by: owner)
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
    plan = Configuration::Profiles::Planner.call(profile: Configuration::Profiles::SoloAutomated, project:, actor: owner)
    Configuration::Profiles::Applier.call(plan:, project:, actor: owner)
    Automation::PhaseSettings::Update.call(project:, user: owner, params: { "phases" => { "operations" => true } })
    ProjectDelegation::SelectPosture.call(project:, actor: owner, level: "bounded_delivery", reason: "Isolated acceptance fixture")
    create(:agent_run, :completed, project:, issue:, goal: "create_pr", completed_at: 2.hours.ago,
      pull_request_number: 42, pull_request_url: source_pr.github_html_url,
      result_commit_sha: "a" * 40, verification_result: { "status" => "passed", "summary" => "Fixture premerge CI" })
    audit = create(:agent_run, :completed, project:, issue:, goal: "analyze_issue",
      result_commit_sha: nil, pull_request_number: nil, pull_request_url: nil)
    audit.update!(reconciliation: { "assessment" => PartialCloseouts::Assessment.snapshot(audit,
      { "criteria" => [ { "criterion" => criterion, "state" => "unmet" } ], "gaps" => [] }) })
    StagedCloseoutAdoption::Mappings.approve(project:, actor: owner, issue:, attributes: {
      criterion_key: criterion, stage: "live_environment", phase: "operations", target_shape: "live_signal",
      execution_path: "trusted_measurement", target_key: "agent_planning_hold_reconciliation_closed_count",
      environment_class: Rails.env.to_s, freshness_seconds: 60, retry_policy: { "max_attempts" => 3 } })
    allow(client).to receive_messages(issue: Struct.new(:state).new("open"), update_issue: Struct.new(:state).new("closed"))
  end

  def finish_audit(audit)
    audit.continuation_request.update!(status: "consumed")
    audit.update!(status: "completed", completed_at: Time.current, result_commit_sha: nil,
      pull_request_number: nil, pull_request_url: nil)
    audit.update!(reconciliation: { "assessment" => PartialCloseouts::Assessment.snapshot(audit, {
      "criteria" => [ { "criterion" => criterion, "state" => "satisfied",
        "evidence" => [ { "label" => "Simulated semantic comparison of measured zero to target zero" } ] } ],
      "gaps" => [], "input_coverage" => { "complete" => true, "reasons" => [] } }) })
  end

  it "refreshes a queued audit's old admission scope before delegated closure" do
    first = CloseoutVerifications::AdmitLiveTarget.call(project:).runs.sole
    CloseoutVerificationJob.perform_now(first.id)
    old_request = IssueContinuationRequest.where(issue:).sole
    old_evidence = old_request.evidence.deep_dup
    travel 61.seconds do
      second = CloseoutVerifications::AdmitLiveTarget.call(project:).runs.sole
      CloseoutVerificationJob.perform_now(second.id)
      old_audit = AgentRun.find_by!(continuation_request: old_request)
      finish_audit(old_audit)
      expect(described_class.call(agent_run: old_audit, client:)).to eq(:not_delegated)
      expect(client).not_to have_received(:update_issue)
      refresh = PartialCloseouts::AutoAudit.call(issue:)
      expect(refresh).to be_scheduled
      finish_audit(refresh.agent_run)
      expect_idempotent_closure(refresh.agent_run)
    end
    expect(old_request.reload.evidence).to eq(old_evidence)
    expect(client).to have_received(:update_issue).once
    expect(source_pr.reload.body).to eq("Tracks ##{issue.github_number}")
    expect(AgentRun.where(issue:, goal: "create_pr").count).to eq(1)
  end

  def expect_idempotent_closure(run)
    expect(described_class.call(agent_run: run, client:)).to eq(:closed)
    expect(described_class.call(agent_run: run, client:)).to eq(:already_closed)
  end
end
