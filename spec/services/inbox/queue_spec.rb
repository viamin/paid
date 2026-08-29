# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::Queue do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) do
    create(
      :project,
      account: account,
      created_by: user,
      auto_pick_enabled: true,
      active: true,
      auto_merge_mode: "all",
      owner_reviewer_login: "viamin",
      owner: "acme",
      repo: "alpha"
    )
  end
  let(:questions_body) do
    <<~BODY
      <!-- paid:enhance-issue -->

      ## Clarifying questions
      1. What is the expected behavior?
    BODY
  end

  # @spec INBOX-FOUNDATION-003 @spec INBOX-FOUNDATION-004
  # @spec INBOX-FOUNDATION-005 @spec INBOX-FOUNDATION-006
  describe ".call" do
    it "returns typed entries for clarifying questions, plan reviews, and merge approvals" do
      issue = create_needs_input(body: questions_body)
      review = create_plan_review(project: project, workflow_id: "planning-workflow-1")
      pr = create_merge_approval_pr

      entries = described_class.call(user: user)

      expect(entries.map(&:kind)).to include(
        described_class::CLARIFYING_QUESTIONS_KIND,
        described_class::PLAN_REVIEW_KIND,
        described_class::MERGE_APPROVAL_KIND
      )
      expect_clarifying_entry(entries, issue)
      expect_plan_review_entry(entries, review)
      expect_merge_approval_entry(entries, pr)
    end

    # @spec OPERATOR-INBOX-002B @spec NOTIFICATION-SEVERITY-008
    it "returns typed entries for visible blocking notifications" do
      notification = create_action_required_notification

      entries = described_class.call(user: user, kind: described_class::ACTION_REQUIRED_KIND)

      action_required_entry = entries.find { |entry| entry.record == notification }
      expect(action_required_entry).to have_attributes(
        id: "#{described_class::ACTION_REQUIRED_KIND}:#{notification.id}",
        kind: described_class::ACTION_REQUIRED_KIND,
        project: project,
        waiting_since: notification.created_at,
        summary_text: "Review the quality dashboard and resume manually or adjust thresholds."
      )
      expect(action_required_entry.tasks).to eq([ "Open the quality dashboard", "Resume manually or adjust thresholds" ])
    end

    it "exposes waiting_since from needs_input_since so a future inbox UI can show waiting age" do
      stamp = 2.days.ago
      issue = create_needs_input(body: questions_body)
      issue.update_columns(needs_input_since: stamp)

      entry = described_class.call(user: user, project: project).find { |candidate| candidate.record == issue }

      expect(entry.waiting_since).to be_within(1.second).of(stamp)
    end

    it "uses locally persisted needs_input_questions for create_feature issues" do
      feature_issue = create_needs_input(
        github_number: 20,
        body: "Need dark mode",
        needs_input_questions: [
          "What is the desired behavior?",
          "What constraints must be respected?"
        ]
      )

      entries = described_class.call(user: user, project: project)

      feature_entry = entries.find { |entry| entry.issue == feature_issue }
      expect(feature_entry.questions).to eq([
        "What is the desired behavior?",
        "What constraints must be respected?"
      ])
    end

    it "skips questionless issues until sync repairs them" do
      questionless = create_needs_input(github_number: 9, body: "Needs manual retry")
      answerable = create_needs_input(github_number: 10, body: questions_body)

      entries = described_class.call(user: user, project: project)

      expect(entries.map(&:issue)).to include(answerable)
      expect(entries.map(&:issue)).not_to include(questionless)
    end

    it "filters to plan reviews when kind: plan_review is requested" do
      create_needs_input(body: questions_body)
      review = create_plan_review(project: project, workflow_id: "planning-workflow-1")

      entries = described_class.call(user: user, kind: described_class::PLAN_REVIEW_KIND)

      expect(entries.map(&:record)).to eq([ review ])
    end

    it "filters to merge approvals when kind: merge_approval is requested" do
      create_needs_input(body: questions_body)
      create_plan_review(project: project, workflow_id: "planning-workflow-1")
      pr = create_merge_approval_pr

      entries = described_class.call(user: user, kind: described_class::MERGE_APPROVAL_KIND)

      expect(entries.map(&:record)).to eq([ pr ])
    end

    it "filters to action_required when kind: action_required is requested" do
      create_needs_input(body: questions_body)
      create_plan_review(project: project, workflow_id: "planning-workflow-1")
      notification = create(:notification, :error, account: account, subject: project, blocking: true)

      entries = described_class.call(user: user, kind: described_class::ACTION_REQUIRED_KIND)

      expect(entries.map(&:record)).to eq([ notification ])
    end

    it "excludes plan reviews that are no longer open" do
      review_issue = create(:issue, project: project)
      create_plan_review(project: project, issue: review_issue, workflow_id: "planning-workflow-1", plan_data: {})
      create(
        :decomposition_decision,
        project: project,
        issue: review_issue,
        workflow_id: "planning-workflow-1",
        decision_key: "planning-workflow-1:plan_review:approved",
        decision_type: "planning_outcome",
        outcome: "plan_review_approved"
      )

      entries = described_class.call(user: user, kind: described_class::PLAN_REVIEW_KIND)

      expect(entries).to be_empty
    end

    it "does not include PRs whose blockers are not approval-only" do
      create_merge_approval_pr(github_number: 10)
      failing_checks = create_merge_approval_pr(github_number: 20)
      unresolved_dependencies = create_merge_approval_pr(github_number: 30)

      failing_checks.update!(
        auto_merge_blockers: snapshot_hash(
          failed: [ blocker(signal: "checks_green", reason_code: "checks_not_green") ],
          not_evaluated: []
        )
      )
      unresolved_dependencies.update!(
        auto_merge_blockers: snapshot_hash(
          failed: [ blocker(signal: "owner_approved", reason_code: "owner_approval_missing") ],
          not_evaluated: [ blocker(signal: "dependencies_resolved", status: "not_evaluated", reason_code: "dependencies_unresolved") ]
        )
      )

      entries = described_class.call(user: user, kind: described_class::MERGE_APPROVAL_KIND)

      expect(entries.map(&:record)).to contain_exactly(project.issues.find_by!(github_number: 10))
    end

    it "excludes non-blocking and inactive notifications from action_required" do
      blocking = create(:notification, :error, account: account, subject: project, blocking: true)
      create(:notification, :error, account: account, subject: project, source: "quota_error", blocking: false)
      create(:notification, :error, :resolved, account: account, subject: project, source: "resolved_blocking", blocking: true)
      create(:notification, :error, :dismissed, account: account, subject: project, source: "dismissed_blocking", blocking: true)

      entries = described_class.call(user: user, kind: described_class::ACTION_REQUIRED_KIND)

      expect(entries.map(&:record)).to eq([ blocking ])
    end

    # @spec OPERATOR-INBOX-002B
    it "links action_required entries for existing-PR agent runs to the source PR, not the originating issue" do
      originating_issue = create(:issue, project: project, github_number: 5)
      pull_request = create(:issue, :pull_request, project: project, github_number: 42)
      agent_run = create(:agent_run, :existing_pr, project: project, issue: originating_issue,
        source_pull_request_number: 42)
      notification = create(:notification, :error, account: account, subject: agent_run,
        source: "guardrail_token_budget", blocking: true)

      entries = described_class.call(user: user, kind: described_class::ACTION_REQUIRED_KIND)

      action_required_entry = entries.find { |entry| entry.record == notification }
      expect(action_required_entry.issue).to eq(pull_request)
    end

    # @spec OPERATOR-INBOX-002B
    it "batch-preloads project and source PR lookups for action_required entries instead of querying per row" do
      create_agent_run_blocking_notification(github_number: 100, source_pull_request_number: 101)
      single_row_queries = count_queries do
        described_class.call(user: user, kind: described_class::ACTION_REQUIRED_KIND)
      end

      create_agent_run_blocking_notification(github_number: 200, source_pull_request_number: 201)
      create_agent_run_blocking_notification(github_number: 300, source_pull_request_number: 301)
      multi_row_queries = count_queries do
        described_class.call(user: user, kind: described_class::ACTION_REQUIRED_KIND)
      end

      expect(multi_row_queries).to eq(single_row_queries)
    end
  end

  describe "ordering" do
    # @spec INBOX-FOUNDATION-004
    it "orders clarifying-question entries oldest-waiting-first by needs_input_since, NULLS LAST" do
      newest = create_needs_input(github_number: 30, body: questions_body)
      oldest = create_needs_input(github_number: 10, body: questions_body)
      middle = create_needs_input(github_number: 20, body: questions_body)
      newest.update_columns(needs_input_since: 1.hour.ago)
      oldest.update_columns(needs_input_since: 3.hours.ago)
      middle.update_columns(needs_input_since: 2.hours.ago)

      order = described_class.call(
        user: user,
        project: project,
        kind: described_class::CLARIFYING_QUESTIONS_KIND
      ).map(&:issue)

      expect(order).to eq([ oldest, middle, newest ])
    end

    it "sorts rows with NULL needs_input_since after rows with a timestamp" do
      with_time = create_needs_input(github_number: 20, body: questions_body)
      without_time = create_needs_input(github_number: 10, body: questions_body)
      with_time.update_columns(needs_input_since: 2.hours.ago)
      without_time.update_columns(needs_input_since: nil)

      order = described_class.call(
        user: user,
        project: project,
        kind: described_class::CLARIFYING_QUESTIONS_KIND
      ).map(&:issue)

      expect(order).to eq([ with_time, without_time ])
    end

    it "tiebreaks by owner, repo, github_number, and id when waiting_since is identical" do
      same_time = Time.current
      first = create_needs_input(github_number: 30, body: questions_body)
      second = create_needs_input(github_number: 10, body: questions_body)
      third = create_needs_input(github_number: 20, body: questions_body)
      [ first, second, third ].each { |issue| issue.update_columns(needs_input_since: same_time) }

      order = described_class.call(
        user: user,
        project: project,
        kind: described_class::CLARIFYING_QUESTIONS_KIND
      ).map(&:issue)

      expect(order).to eq([ second, third, first ])
    end

    it "orders mixed inbox entries by waiting_since with NULL clarifying timestamps last" do
      clarifying = create_needs_input(github_number: 10, body: questions_body)
      clarifying.update_columns(needs_input_since: nil)
      review = create_plan_review(project: project, workflow_id: "planning-workflow-1")
      approval = create_merge_approval_pr(github_number: 30, waiting_since: 2.days.ago)

      order = described_class.call(user: user).map(&:record)

      expect(order).to eq([ approval, review, clarifying ])
    end
  end

  describe "including PRs" do
    # @spec INBOX-FOUNDATION-005
    it "includes pull requests alongside issues for clarifying-question entries" do
      issue = create_needs_input(github_number: 10, body: questions_body)
      pr = create(:issue, :needs_input, :pull_request, project: project, github_number: 20, body: questions_body)

      entries = described_class.call(
        user: user,
        project: project,
        kind: described_class::CLARIFYING_QUESTIONS_KIND
      )

      expect(entries.map(&:issue)).to contain_exactly(issue, pr)
    end
  end

  describe "scoping" do
    # @spec INBOX-FOUNDATION-006
    it "only returns clarifying-question entries from auto-pick projects" do
      other_project = create(:project, account: account, created_by: user, auto_pick_enabled: false, active: true)
      in_scope = create_needs_input(github_number: 10, body: questions_body)
      out_of_scope = create_needs_input(github_number: 20, project: other_project, body: questions_body)

      entries = described_class.call(user: user, kind: described_class::CLARIFYING_QUESTIONS_KIND)

      expect(entries.map(&:issue)).to include(in_scope)
      expect(entries.map(&:issue)).not_to include(out_of_scope)
    end

    it "narrows to a single project when project: is provided" do
      scoped_issue = create_needs_input(github_number: 10, body: questions_body)
      scoped_review = create_plan_review(project: project, workflow_id: "planning-workflow-1")
      scoped_notification = create(:notification, :error, account: account, subject: project, source: "action_required_alpha", blocking: true)
      other_project = create(
        :project,
        account: account,
        created_by: user,
        auto_pick_enabled: true,
        active: true,
        owner: "acme",
        repo: "beta"
      )
      create_needs_input(github_number: 11, project: other_project, body: questions_body)
      create_plan_review(project: other_project, workflow_id: "planning-workflow-2")
      other_notification = create(:notification, :error, account: account, subject: other_project, source: "action_required_beta", blocking: true)

      entries = described_class.call(user: user, project: project)

      expect(entries.map(&:record)).to include(scoped_issue, scoped_review, scoped_notification)
      expect(entries.map(&:record)).not_to include(other_notification)
    end

    it "excludes clarifying-question projects from other accounts" do
      other_user = create(:user, account: create(:account))
      other_account_project = create(
        :project,
        account: other_user.account,
        created_by: other_user,
        auto_pick_enabled: true,
        active: true
      )
      create_needs_input(github_number: 20, project: other_account_project, body: questions_body)
      mine = create_needs_input(github_number: 10, body: questions_body)

      entries = described_class.call(user: user, kind: described_class::CLARIFYING_QUESTIONS_KIND)

      expect(entries.map(&:issue)).to contain_exactly(mine)
    end
  end

  def create_needs_input(overrides = {})
    defaults = { project: project, github_number: 10 }
    create(:issue, :needs_input, **defaults.merge(overrides))
  end

  def create_plan_review(project:, workflow_id:, issue: create(:issue, project: project), plan_data: nil)
    create(
      :decomposition_decision,
      project: project,
      issue: issue,
      workflow_id: workflow_id,
      decision_key: "#{workflow_id}:plan_review:pending",
      decision_type: "planning_outcome",
      outcome: "plan_pending_review",
      plan_data: plan_data || { "tasks" => [ { "title" => "Task 1", "description" => "Do the thing" } ] }
    )
  end

  def create_merge_approval_pr(github_number: 40, waiting_since: 2.hours.ago, blockers: nil)
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: github_number,
      github_updated_at: waiting_since,
      awaiting_approval_since: waiting_since,
      auto_merge_evaluated_at: Time.current,
      auto_merge_blockers: blockers || snapshot_hash(
        failed: [ blocker(signal: "owner_approved", reason_code: "owner_approval_missing") ],
        not_evaluated: []
      )
    )
  end

  def create_agent_run_blocking_notification(github_number:, source_pull_request_number:)
    originating_issue = create(:issue, project: project, github_number: github_number)
    create(:issue, :pull_request, project: project, github_number: source_pull_request_number)
    agent_run = create(:agent_run, :existing_pr, project: project, issue: originating_issue,
      source_pull_request_number: source_pull_request_number)
    create(:notification, :error, account: account, subject: agent_run,
      source: "guardrail_token_budget", blocking: true)
  end

  def create_action_required_notification(subject: project, source: "quality_auto_resume_cooldown")
    create(
      :notification,
      :error,
      account: account,
      subject: subject,
      source: source,
      blocking: true,
      title: "Quality pause requires manual review",
      metadata: {
        "recommended_action" => "Review the quality dashboard and resume manually or adjust thresholds.",
        "remediation_steps" => [ "Open the quality dashboard", "Resume manually or adjust thresholds" ]
      }
    )
  end

  def snapshot_hash(failed:, not_evaluated:)
    { "failed" => failed, "not_evaluated" => not_evaluated }
  end

  def blocker(signal:, reason_code:, status: "failed")
    {
      "signal" => signal,
      "status" => status,
      "reason_code" => reason_code,
      "sanitized_message" => "#{signal} is blocking auto-merge",
      "next_action" => "Resolve #{reason_code}"
    }
  end

  def expect_clarifying_entry(entries, issue)
    clarifying_entry = entries.find { |entry| entry.record == issue }

    expect(clarifying_entry).to have_attributes(
      id: "#{described_class::CLARIFYING_QUESTIONS_KIND}:#{issue.id}",
      kind: described_class::CLARIFYING_QUESTIONS_KIND,
      project: project,
      issue: issue,
      questions: [ "What is the expected behavior?" ],
      tasks: []
    )
  end

  def expect_plan_review_entry(entries, review)
    plan_review_entry = entries.find { |entry| entry.record == review }

    expect(plan_review_entry).to have_attributes(
      id: "#{described_class::PLAN_REVIEW_KIND}:#{review.id}",
      kind: described_class::PLAN_REVIEW_KIND,
      project: project,
      issue: review.issue,
      tasks: [ { "title" => "Task 1", "description" => "Do the thing" } ],
      questions: []
    )
  end

  def expect_merge_approval_entry(entries, pr)
    approval_entry = entries.find { |entry| entry.record == pr }

    expect(approval_entry).to have_attributes(
      id: "#{described_class::MERGE_APPROVAL_KIND}:#{pr.id}",
      kind: described_class::MERGE_APPROVAL_KIND,
      project: project,
      issue: pr,
      tasks: [],
      questions: [],
      waiting_since: pr.awaiting_approval_since
    )
    expect(approval_entry.summary).to eq("Waiting for owner approval")
  end
end
