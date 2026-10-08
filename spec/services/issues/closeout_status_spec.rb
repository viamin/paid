# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::CloseoutStatus do # @spec PARTIAL-CLOSEOUT-002
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, owner: "acme", repo: "alpha") }
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }

  def merged_partial_pr(number:)
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: number,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: issue.id,
      created_at: 2.days.ago
    )
  end

  def synthetic_scanner_issue
    create(:issue, project: project, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
      github_number: 200_001_838, github_issue_id: Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET + 1838,
      github_state: "open", paid_state: "in_progress")
  end

  it "marks an issue with merged partial evidence stalled and explains the exact reason" do
    merged_partial_pr(number: 12)

    status = described_class.call(issue)

    expect(status.stalled?).to be(true)
    expect(status.reason).to include("merged")
    expect(status.reason).to include("#12")
    expect(status.evidence.merged_prs.map(&:number)).to contain_exactly(12)
  end

  it "reports the recorded completion outcome for no-code evidence" do
    issue.update!(paid_state: "completed", no_code_required_at: 3.hours.ago)

    status = described_class.call(issue.reload)

    expect(status.stalled?).to be(true)
    expect(status.evidence.no_code_required_at).to be_present
    expect(status.outcome).to include("no code required")
  end

  it "lists unresolved prerequisites blocking continuation" do
    merged_partial_pr(number: 12)
    blocker = create(:issue, project: project, github_state: "open", github_number: 44)
    create(:issue_dependency, issue: issue, depends_on_issue: blocker)

    status = described_class.call(issue)

    expect(status.unresolved_prerequisites).to include("#44")
  end

  it "explains an active issue-analysis backoff as the continuation blocker" do
    merged_partial_pr(number: 12)
    issue.update_columns(
      issue_analysis_next_attempt_at: 2.hours.from_now,
      issue_analysis_backoff_set_at: 1.hour.ago
    )

    status = described_class.call(issue.reload)

    expect(status.blocker_codes).to include(:analysis_backoff)
    expect(status.reason).to include("backoff")
  end

  it "surfaces a non-walked eligibility guard via the scoped preflight instead of the duplicate-work fallback" do
    merged_partial_pr(number: 12)
    create(
      :issue,
      project: project,
      github_state: "open",
      paid_state: "in_progress",
      parent_issue_id: issue.id,
      github_number: 55
    )

    status = described_class.call(issue)

    expect(status.stalled?).to be(true)
    expect(status.blocker_codes).to contain_exactly(:unavailable)
    expect(status.reason).to include("unavailable")
    expect(status.blockers.first.recovery).to include("Investigate")
  end

  it "reports every material blocker, including scanner verification evidence, without treating a merge as a fix" do
    # @spec PARTIAL-CLOSEOUT-012 EAGER-QUEUE-013
    synthetic_issue = synthetic_scanner_issue
    create(:issue, :pull_request, project: project, github_number: 4034,
      github_state: "closed", pr_review_phase: "merged", parent_issue: synthetic_issue)
    attempt = create(:code_scanning_remediation_attempt, issue: synthetic_issue,
      status: "verification_blocked", verification_analysis_id: "1842809913",
      blocked_reason: "analysis is unavailable")
    dependency = create(:issue, project: project, github_number: 44, github_state: "open")
    create(:issue_dependency, issue: synthetic_issue, depends_on_issue: dependency)

    status = described_class.call(synthetic_issue)

    expect(status.blocker_codes).to include(:unmet_prerequisites, :scanner_verification_retryable)
    scanner = status.blockers.find { |blocker| blocker.code == :scanner_verification_retryable }
    expect(scanner.evidence).to include("attempt_id" => attempt.id, "analysis_id" => "1842809913")
    expect(scanner.message).to include("not proof it is fixed")
    expect(scanner.recovery.downcase).to include("wait")
  end

  it "labels scanner-confirmed alert 1838 evidence as a recurrence, rather than a merge fix" do
    # @spec PARTIAL-CLOSEOUT-012 EAGER-QUEUE-013
    synthetic_issue = synthetic_scanner_issue
    merged_partial_pr = create(:issue, :pull_request, project: project, github_number: 4034,
      github_state: "closed", pr_review_phase: "merged", parent_issue: synthetic_issue)
    attempt = create(:code_scanning_remediation_attempt, issue: synthetic_issue,
      status: "verification_failed", pull_request_number: merged_partial_pr.github_number,
      verification_analysis_id: "1842809913", verification_commit_sha: "post-merge-sha")

    status = described_class.call(synthetic_issue)

    recurrence = status.blockers.find { |blocker| blocker.code == :scanner_verification_failed }
    expect(recurrence.message).to include("scanner-confirmed recurrence")
    expect(recurrence.evidence).to include(
      "attempt_id" => attempt.id, "alert_number" => 1838, "recurrent" => true,
      "analysis_id" => "1842809913", "analysis_commit_sha" => "post-merge-sha"
    )
  end

  it "is not stalled without closeout evidence" do
    status = described_class.call(issue)

    expect(status.stalled?).to be(false)
    expect(status.reason).to be_present
  end

  it "is not stalled while an open continuation request authorizes the issue" do
    merged_partial_pr(number: 12)
    create(:issue_continuation_request, issue: issue, project: project)

    expect(described_class.call(issue.reload).stalled?).to be(false)
  end

  it "is not stalled when resolved complete against the current evidence generation" do
    merged_partial_pr(number: 12)
    issue.update!(
      closeout_resolved_at: 1.hour.ago,
      closeout_resolution_digest: described_class.call(issue).evidence.digest,
      closeout_resolved_by_id: create(:user, account: account).id
    )

    expect(described_class.call(issue.reload).stalled?).to be(false)
  end

  it "is stalled again after a resolution when newer terminal evidence arrives" do
    merged_partial_pr(number: 12)
    issue.update!(
      closeout_resolved_at: 3.days.ago,
      closeout_resolution_digest: described_class.call(issue).evidence.digest,
      closeout_resolved_by_id: create(:user, account: account).id
    )
    merged_partial_pr(number: 13)

    expect(described_class.call(issue.reload).stalled?).to be(true)
  end
end
