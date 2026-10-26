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

  def expect_human_prerequisite_evidence(blocker, notification)
    expect(blocker.evidence.fetch("notifications")).to include(hash_including(
      "notification_id" => notification.id,
      "notification_url" => "/inbox/action_required:#{notification.id}",
      "description" => "Select the approved review policy and record the human evidence.",
      "issue_number" => issue.github_number,
      "issue_url" => issue.github_url
    ))
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

  # @spec PARTIAL-CLOSEOUT-030
  it "keeps the unavailable fallback for a genuinely undiagnosed scoped denial" do
    merged_partial_pr(number: 12)

    status = described_class.call(issue, eligible_issue_ids: [], continuation_eligible_issue_ids: [])

    expect(status.stalled?).to be(true)
    expect(status.blocker_codes).to contain_exactly(:unavailable)
    expect(status.reason).to include("unavailable")
    expect(status.blockers.first.recovery).to include("Investigate")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "explains an active partial-closeout human prerequisite notification with its evidence and Inbox route" do
    merged_partial_pr(number: 12)
    notification = create(
      :notification,
      :error,
      account: account,
      subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      blocking: true,
      title: "Choose the release policy",
      description: "Select the approved review policy and record the human evidence."
    )

    status = described_class.call(issue)
    blocker = status.blockers.find { |candidate| candidate.code == :human_prerequisite }

    expect(status.blocker_codes).to include(:human_prerequisite)
    expect(status.reason).to include("Choose the release policy")
    expect_human_prerequisite_evidence(blocker, notification)
    expect(blocker.recovery).to include("human decision or evidence")
    expect(blocker.recovery).to include("policy-selection")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "explains an open native child without requiring a duplicate dependency edge" do
    merged_partial_pr(number: 12)
    child = create(:issue, project: project, github_number: 4596, github_state: "open", paid_state: "in_progress", parent_issue: issue)

    status = described_class.call(issue)
    blocker = status.blockers.find { |candidate| candidate.code == :open_native_children }

    expect(issue.issue_dependencies).to be_empty
    expect(status.blocker_codes).to include(:open_native_children)
    expect(blocker.message).to include("#4596")
    expect(blocker.evidence).to include(
      "children" => [ { "id" => child.id, "number" => 4596, "url" => child.github_url } ]
    )
    expect(blocker.recovery).to include("#4596")
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "does not expose a cross-tenant notification as this issue's human prerequisite" do
    merged_partial_pr(number: 12)
    other_account = create(:account)
    create(:notification, :error, account: other_account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      title: "Other tenant evidence", description: "This must not block another tenant.")

    status = described_class.call(issue, eligible_issue_ids: [], continuation_eligible_issue_ids: [])

    expect(status.blocker_codes).not_to include(:human_prerequisite)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "enumerates native-child and human-prerequisite guards together" do
    merged_partial_pr(number: 12)
    create(:issue, project: project, github_number: 4596, github_state: "open", paid_state: "in_progress", parent_issue: issue)
    create(:notification, :error, account: account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      title: "Approve rollout", description: "Record the required approval.")

    status = described_class.call(issue)

    expect(status.blocker_codes).to include(:open_native_children, :human_prerequisite)
    expect(status.reason).to include("#4596", "Approve rollout")
    expect(status.blocker_codes).not_to include(:unavailable)
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
