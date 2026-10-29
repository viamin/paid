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

  def human_prerequisite_notification
    create(
      :notification,
      :error,
      account: account,
      subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      blocking: true,
      title: "Choose the review policy",
      description: "Record the human adjudication and its evidence.",
      action_url: "/inbox/action_required:2777"
    )
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

  it "explains an open native child without requiring a duplicate dependency edge" do # @spec PARTIAL-CLOSEOUT-030
    merged_partial_pr(number: 12)
    child = create(
      :issue,
      project: project,
      github_state: "open",
      paid_state: "in_progress",
      parent_issue_id: issue.id,
      github_number: 55,
      github_html_url: "https://github.com/acme/alpha/issues/55"
    )

    status = described_class.call(issue)

    expect(status.stalled?).to be(true)
    expect(status.blocker_codes).to contain_exactly(:open_native_children)
    expect(status.reason).to include("#55")
    expect(status.blockers.first.evidence).to include(
      "children" => [ hash_including("id" => child.id, "number" => 55, "url" => child.github_url) ]
    )
    expect(status.blockers.first.recovery).to include("Do not close")
  end

  it "preloads native child projects for singleton and batched diagnostics" do # @spec PARTIAL-CLOSEOUT-030
    merged_partial_pr(number: 12)
    3.times do |index|
      create(:issue, project: project, github_state: "open", paid_state: "in_progress",
        parent_issue_id: issue.id, github_number: 55 + index, github_html_url: nil)
    end
    project_query = /SELECT .* FROM "projects" WHERE "projects"\."id" =/

    singleton_queries = []
    batched_queries = []
    singleton_subscriber = ->(*args) { singleton_queries << ActiveSupport::Notifications::Event.new(*args).payload[:sql] }
    batched_subscriber = ->(*args) { batched_queries << ActiveSupport::Notifications::Event.new(*args).payload[:sql] }
    ActiveSupport::Notifications.subscribed(singleton_subscriber, "sql.active_record") do
      described_class.call(issue)
    end
    ActiveSupport::Notifications.subscribed(batched_subscriber, "sql.active_record") do
      inputs = described_class.inputs_for([ issue ])
      described_class.call(issue, eligible_issue_ids: [], continuation_eligible_issue_ids: [], inputs: inputs)
    end

    expect(singleton_queries.grep(project_query).size).to be <= 2
    expect(batched_queries.grep(project_query).size).to be <= 2
  end

  it "uses the unavailable fallback for a genuinely unclassified admission denial" do # @spec PARTIAL-CLOSEOUT-030
    merged_partial_pr(number: 12)
    feature = create(:feature_intent, project: project)
    amendment = create(:design_amendment, feature_intent: feature, project: project, status: "merged")
    create(:design_amendment_pause, design_amendment: amendment, issue: issue, reason_code: "affected")

    status = described_class.call(issue)

    expect(status.stalled?).to be(true)
    expect(status.blocker_codes).to contain_exactly(:unavailable)
    expect(status.reason).to include("exact guard is unavailable")
    expect(status.blockers.first.recovery).to include("Investigate")
  end

  it "explains active partial-closeout human prerequisite notifications and every simultaneous guard" do # @spec PARTIAL-CLOSEOUT-030
    merged_partial_pr(number: 12)
    child = create(:issue, project: project, github_state: "open", paid_state: "in_progress", parent_issue_id: issue.id, github_number: 55)
    notification = human_prerequisite_notification

    status = described_class.call(issue)

    expect(status.blocker_codes).to contain_exactly(:open_native_children, :human_prerequisite_notification)
    notification_blocker = status.blockers.find { |blocker| blocker.code == :human_prerequisite_notification }
    expect(notification_blocker.message).to include("##{notification.id}")
    expect(notification_blocker.evidence.fetch("notifications").first).to include(
      "notification_id" => notification.id,
      "source" => PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      "action_url" => "/inbox/action_required:2777"
    )
    expect(notification_blocker.recovery).to include("human decision or evidence")
    expect(status.blockers.first.evidence.fetch("children")).to include(hash_including("id" => child.id))
  end

  it "names the external prerequisite, synced state, owner, and retry path" do # @spec PARTIAL-CLOSEOUT-038
    merged_partial_pr(number: 12)
    target_project = create(:project, account:, owner: "viamin", repo: "agent-harness", name: "agent-harness")
    create(:issue, project: target_project, github_number: 517, github_state: "open", paid_state: "in_progress",
      github_creator_login: "dependency-owner")
    create(:issue_dependency, issue:, depends_on_issue: nil,
      depends_on_owner: "viamin", depends_on_repo: "agent-harness", depends_on_number: 517)
    create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      title: "External work is pending", description: "Wait for viamin/agent-harness#517.",
      metadata: { "prerequisites" => [ {
        "identity" => "agent-harness-517", "criterion" => "Agent harness support", "kind" => "external",
        "external_dependency" => { "owner" => "viamin", "repo" => "agent-harness", "number" => 517 }
      } ] })

    blocker = described_class.call(issue).blockers.find { |candidate| candidate.code == :prerequisite_notification }

    expect(blocker.message).to include("viamin/agent-harness#517", "open", "@dependency-owner")
    expect(blocker.evidence.fetch("links")).to include(hash_including("label" => "viamin/agent-harness#517"))
    expect(blocker.recovery).to include("rechecks")
  end

  it "batch-loads external prerequisite targets for every rendered notification" do # @spec PARTIAL-CLOSEOUT-026
    target_project = create(:project, account:, owner: "viamin", repo: "agent-harness", name: "agent-harness")
    dependents = []
    3.times do |index|
      target = create(:issue, project: target_project, github_number: 517 + index, github_state: "open")
      dependent = create(:issue, project:, github_state: "open", paid_state: "in_progress")
      create(:issue_dependency, issue: dependent, depends_on_issue: nil,
        depends_on_owner: "viamin", depends_on_repo: "agent-harness", depends_on_number: target.github_number)
      create(:notification, :error, account:, subject: dependent,
        source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
        metadata: { "prerequisites" => [ {
          "identity" => "agent-harness-#{target.github_number}", "kind" => "external",
          "external_dependency" => { "owner" => "viamin", "repo" => "agent-harness", "number" => target.github_number }
        } ] })
      dependents << dependent
    end

    queries = []
    subscriber = ->(*args) { queries << ActiveSupport::Notifications::Event.new(*args).payload[:sql] }
    inputs = nil
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      inputs = described_class.inputs_for(dependents)
      dependents.each do |dependent|
        described_class.call(dependent, eligible_issue_ids: [], continuation_eligible_issue_ids: [], inputs: inputs)
      end
    end

    expect(inputs.external_prerequisite_states_by_notification_id.values.flatten).to all(include("state" => "open"))
    expect(queries.grep(/FROM "projects" WHERE.*LOWER/).size).to eq(1)
  end

  it "does not cross-pair batched child and notification blockers across tenants" do # @spec PARTIAL-CLOSEOUT-030
    other_account = create(:account)
    other_project = create(:project, account: other_account)
    other_issue = create(:issue, project: other_project, github_state: "open", paid_state: "in_progress")
    foreign_child = create(:issue, project: other_project, parent_issue_id: other_issue.id,
      github_state: "open", paid_state: "in_progress")
    foreign_child.update_column(:project_id, project.id)
    foreign_notification = create(:notification, :error, account: account, subject: other_issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true)

    inputs = described_class.inputs_for([ issue, other_issue ])

    expect(inputs.open_native_children_by_issue_id.fetch(other_issue.id, [])).not_to include(foreign_child)
    expect(inputs.prerequisite_notifications_by_issue_id.fetch(other_issue.id, [])).not_to include(foreign_notification)
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
