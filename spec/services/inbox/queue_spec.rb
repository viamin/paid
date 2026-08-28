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

      entries = described_class.call(user: user, project: project)

      expect(entries.map(&:record)).to contain_exactly(scoped_issue, scoped_review)
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
