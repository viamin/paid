# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::CloseoutStatus do # @spec PARTIAL-CLOSEOUT-002
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, owner: "acme", repo: "alpha") }
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }

  # @spec OPERATOR-INBOX-016
  it "reads prerequisites once for both blockers and the status summary" do
    issue
    queries = []
    subscriber = ->(*args) { queries << ActiveSupport::Notifications::Event.new(*args).payload[:sql] }

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      described_class.call(issue, eligible_issue_ids: [], continuation_eligible_issue_ids: [])
    end

    expect(queries.grep(/SELECT "issues"\."github_number" FROM "issues"/).size).to eq(1)
  end

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

  # @spec PARTIAL-CLOSEOUT-026
  it "orders batched prerequisites exactly like the singleton path, numerically by PR number" do
    merged_partial_pr(number: 12)
    create(:issue_dependency, issue: issue, depends_on_issue: create(:issue, project: project, github_state: "open", github_number: 10))
    create(:issue_dependency, issue: issue, depends_on_issue: create(:issue, project: project, github_state: "open", github_number: 9))

    inputs = described_class.inputs_for([ issue ])
    batched = described_class.call(issue, eligible_issue_ids: [], continuation_eligible_issue_ids: [], inputs: inputs)
    singleton = described_class.call(issue, eligible_issue_ids: [], continuation_eligible_issue_ids: [])

    expect(inputs.prerequisites_by_issue_id[issue.id]).to eq([ "#9", "#10" ])
    expect(batched.unresolved_prerequisites).to eq(singleton.unresolved_prerequisites)
  end

  # @spec PARTIAL-CLOSEOUT-026
  it "surfaces the same feature-hold denial as the singleton path when several links are held" do
    merged_partial_pr(number: 12)
    revising = create(:feature_intent, project: project, status: "revising")
    create(:feature_intent_issue, feature_intent: revising, issue: issue)
    unreleased = create(:feature_intent, project: project, status: "approved_waiting_for_merge")
    create(:feature_intent_issue, feature_intent: unreleased, issue: issue)

    inputs = described_class.inputs_for([ issue ])
    batched = described_class.call(issue, eligible_issue_ids: [], continuation_eligible_issue_ids: [], inputs: inputs)
    singleton = described_class.call(issue, eligible_issue_ids: [], continuation_eligible_issue_ids: [])

    expect(inputs.feature_links_by_issue_id[issue.id].map(&:id)).to eq(inputs.feature_links_by_issue_id[issue.id].map(&:id).sort)
    expect(batched.blocker_codes).to eq([ :feature_held ])
    expect(batched.reason).to eq(singleton.reason)
    expect(batched.reason).to include("revising")
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
    # A guard no walked diagnostic covers: the originating run recorded a PR
    # number inside the PR-sync grace window with no local closed-unmerged PR
    # row proving the outcome (#3432), so the scoped preflight alone rejects.
    create(:agent_run, :completed, project: project, issue: issue, goal: "create_pr",
      pull_request_number: 12, completed_at: 5.minutes.ago)

    status = described_class.call(issue)

    expect(status.stalled?).to be(true)
    expect(status.blocker_codes).to contain_exactly(:unavailable)
    expect(status.reason).to include("unavailable")
    expect(status.blockers.first.recovery).to include("Investigate")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "explains an open native sub-issue by identity instead of the unknown-guard fallback (#4323-like)" do
    merged_partial_pr(number: 12)
    create(:issue, project: project, github_state: "open", paid_state: "in_progress",
      parent_issue_id: issue.id, github_number: 55)

    status = described_class.call(issue)

    expect(status.stalled?).to be(true)
    expect(status.blocker_codes).to contain_exactly(:open_sub_issues)
    blocker = status.blockers.first
    expect(blocker.message).to include("#55")
    expect(blocker.evidence["children"]).to contain_exactly(
      hash_including("number" => 55, "url" => ending_with("/issues/55"), "paid_state" => "in_progress")
    )
    expect(blocker.recovery).to be_present
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "does not treat native children parked for closure or completed as admission blockers" do
    merged_partial_pr(number: 12)
    create(:issue, project: project, github_state: "open", paid_state: "recommend_close",
      parent_issue_id: issue.id, github_number: 61)
    create(:issue, project: project, github_state: "open", paid_state: "completed",
      parent_issue_id: issue.id, github_number: 62)

    status = described_class.call(issue)

    expect(status.blocker_codes).not_to include(:open_sub_issues)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "reports a dependency-edged child once, through the prerequisite blocker, without a duplicate edge" do
    merged_partial_pr(number: 12)
    child = create(:issue, project: project, github_state: "open", paid_state: "in_progress",
      parent_issue_id: issue.id, github_number: 63)
    create(:issue_dependency, issue: issue, depends_on_issue: child)

    status = described_class.call(issue)

    expect(status.blocker_codes).to contain_exactly(:unmet_prerequisites)
    expect(status.blockers.first.message).to include("#63")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "explains an active human-prerequisite notification instead of the unknown-guard fallback (#3861-like)" do
    merged_partial_pr(number: 12)
    notification = create(:notification, :error, account: account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      title: "Human adjudication needs operator action",
      description: "Two independent reviewers: record both adjudications on the issue",
      action_url: "/inbox/action_required:#{issue.id}")

    status = described_class.call(issue)

    expect(status.stalled?).to be(true)
    expect(status.blocker_codes).to contain_exactly(:human_prerequisite)
    blocker = status.blockers.first
    expect(blocker.message).to include("Human adjudication needs operator action")
    expect(blocker.message).to include("human decision").and include("not missing implementation")
    expect(blocker.evidence).to include(
      "notification_id" => notification.id,
      "title" => "Human adjudication needs operator action",
      "notification_url" => "/inbox/action_required:#{issue.id}"
    )
    expect(blocker.evidence["requested_at"]).to be_present
    expect(blocker.recovery).to include("dismiss")
    expect(notification.reload.active?).to be(true)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "clears the human-prerequisite blocker once the notification is dismissed or resolved" do
    merged_partial_pr(number: 12)
    notification = create(:notification, :error, account: account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      title: "Pilot results need operator action", description: "Attach the p95")
    notification.update_columns(dismissed_at: Time.current)

    status = described_class.call(issue)

    expect(status.blocker_codes).not_to include(:human_prerequisite)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "ignores prerequisite notifications from another account (tenant isolation)" do
    merged_partial_pr(number: 12)
    other_account = create(:account)
    create(:notification, :error, account: other_account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      title: "Other tenant", description: "not this tenant's block")

    status = described_class.call(issue)

    expect(status.blocker_codes).not_to include(:human_prerequisite)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "reconciles notification guidance that predates newer terminal evidence as stale" do
    merged_partial_pr(number: 12)
    notification = create(:notification, :error, account: account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      title: "Pilot results need operator action", description: "Attach the p95",
      created_at: 3.days.ago)
    merged_partial_pr(number: 13)

    status = described_class.call(issue.reload)

    blocker = status.blockers.find { |candidate| candidate.code == :human_prerequisite }
    expect(blocker.evidence["guidance_stale"]).to be(true)
    expect(blocker.evidence["stale_reasons"]).to include(a_string_including("newer terminal closeout evidence"))
    expect(blocker.recovery).to include("acceptance audit")
    expect(notification.reload.active?).to be(true)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "reconciles notification guidance that predates an explicit solo evaluation policy selection" do
    merged_partial_pr(number: 12)
    notification = create(:notification, :error, account: account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      title: "Two reviewers need operator action",
      description: "Two independent reviewers: record both adjudications",
      created_at: 4.days.ago)
    create(:intent_conformance_shadow_evaluation, project: project, created_at: 1.day.ago)

    status = described_class.call(issue)

    blocker = status.blockers.find { |candidate| candidate.code == :human_prerequisite }
    expect(blocker.evidence["guidance_stale"]).to be(true)
    expect(blocker.evidence["stale_reasons"]).to include(a_string_including("solo-maintainer evaluation policy selection"))
    expect(blocker.recovery).to include("solo")
    expect(blocker.recovery).to include("never")
    expect(notification.reload.active?).to be(true)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "enumerates simultaneous native-child, notification, and dependency blockers" do
    merged_partial_pr(number: 12)
    create(:issue, project: project, github_state: "open", paid_state: "in_progress",
      parent_issue_id: issue.id, github_number: 71)
    create(:issue_dependency, issue: issue,
      depends_on_issue: create(:issue, project: project, github_state: "open", github_number: 72))
    create(:notification, :error, account: account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      title: "Pilot results need operator action", description: "Attach the p95")

    status = described_class.call(issue)

    expect(status.blocker_codes).to contain_exactly(:unmet_prerequisites, :open_sub_issues, :human_prerequisite)
  end

  # @spec PARTIAL-CLOSEOUT-026
  it "surfaces the same native-child and notification blockers from batched inputs as the singleton path" do
    merged_partial_pr(number: 12)
    create(:issue, project: project, github_state: "open", paid_state: "in_progress",
      parent_issue_id: issue.id, github_number: 73)
    create(:notification, :error, account: account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      title: "Pilot results need operator action", description: "Attach the p95")

    inputs = described_class.inputs_for([ issue ])
    batched = described_class.call(issue, eligible_issue_ids: [], continuation_eligible_issue_ids: [], inputs: inputs)
    singleton = described_class.call(issue, eligible_issue_ids: [], continuation_eligible_issue_ids: [])

    expect(batched.blocker_codes).to eq(singleton.blocker_codes)
    expect(batched.reason).to eq(singleton.reason)
    expect(batched.blocker_codes).to contain_exactly(:open_sub_issues, :human_prerequisite)
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
