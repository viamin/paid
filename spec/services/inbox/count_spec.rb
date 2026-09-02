# frozen_string_literal: true

require "rails_helper"

# @spec OPERATOR-INBOX-010
RSpec.describe Inbox::Count do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

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

  describe ".call" do
    it "counts needs_input candidates, merge approvals, and open plan reviews" do
      create(:issue, :needs_input, project: project)
      create(:issue, :needs_input, project: project)
      create_merge_approval_pr
      create(:decomposition_decision, project: project, workflow_id: "wf-1", decision_key: "wf-1:pending", decision_type: "planning_outcome", outcome: "plan_pending_review")
      create(:notification, :error, account: account, subject: project, blocking: true)

      expect(described_class.call(user: user)).to eq(5)
    end

    it "excludes closed issues and issues on non-gated projects" do
      create(:issue, :needs_input, project: project)
      create(:issue, :closed, :needs_input, project: project)
      other_project = create(:project, account: account, created_by: user, auto_pick_enabled: false, active: true, owner: "acme", repo: "beta")
      create(:issue, :needs_input, project: other_project)

      expect(described_class.call(user: user)).to eq(1)
    end

    it "returns zero when nothing is waiting" do
      expect(described_class.call(user: user)).to eq(0)
    end

    it "refreshes the cached count after the inbox cache version bumps" do
      # Created directly through the factory (bypassing
      # Orchestration::DecompositionDecisions::Log) so this mutation does not
      # itself trigger the auto-invalidation covered by the tests below —
      # isolating what's under test here to the TTL cache behavior.
      create(:decomposition_decision, project: project, workflow_id: "wf-1", decision_key: "wf-1:pending", decision_type: "planning_outcome", outcome: "plan_pending_review")
      first = described_class.call(user: user)

      create(:decomposition_decision, project: project, workflow_id: "wf-2", decision_key: "wf-2:pending", decision_type: "planning_outcome", outcome: "plan_pending_review")
      cached = described_class.call(user: user)
      Dashboard::CacheVersion.bump(account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
      refreshed = described_class.call(user: user)

      expect(first).to eq(1)
      expect(cached).to eq(1)
      expect(refreshed).to eq(2)
    end

    it "bumps the cache automatically when an issue transitions into needs_input" do
      issue = create(:issue, project: project)
      first = described_class.call(user: user)

      issue.update!(paid_state: "needs_input")
      refreshed = described_class.call(user: user)

      expect(first).to eq(0)
      expect(refreshed).to eq(1)
    end

    it "refreshes the cached count when a needs_input issue closes and reopens on GitHub" do
      issue = create(:issue, :needs_input, project: project)
      first = described_class.call(user: user)

      issue.update!(github_state: "closed")
      after_close = described_class.call(user: user)

      issue.update!(github_state: "open")
      after_reopen = described_class.call(user: user)

      expect(first).to eq(1)
      expect(after_close).to eq(0)
      expect(after_reopen).to eq(1)
    end

    it "bumps the cache automatically when a plan review decision is logged" do
      Strategies::SeedBaselineOrchestration.call
      first = described_class.call(user: user)

      Orchestration::DecompositionDecisions::Log.call(
        project_id: project.id,
        issue_id: create(:issue, project: project).id,
        decision_key: "wf-2:pending",
        workflow_name: "Workflows::PlanningWorkflow",
        workflow_id: "wf-2",
        decision_type: "planning_outcome",
        outcome: "plan_pending_review"
      )
      refreshed = described_class.call(user: user)

      expect(first).to eq(0)
      expect(refreshed).to eq(1)
    end

    # @spec OPERATOR-INBOX-002B @spec NOTIFICATION-SEVERITY-008
    it "bumps the cache automatically when a blocking notification enters or leaves the inbox" do
      first = described_class.call(user: user)

      notification = create(:notification, :error, account: account, subject: project, blocking: true)
      after_create = described_class.call(user: user)

      notification.update!(resolved_at: Time.current)
      after_resolve = described_class.call(user: user)

      expect(first).to eq(0)
      expect(after_create).to eq(1)
      expect(after_resolve).to eq(0)
    end

    # @spec OPERATOR-INBOX-002B
    it "excludes blocking notifications whose subject does not resolve to a project" do
      create(:notification, :error, account: account, subject: account, blocking: true)

      expect(described_class.call(user: user)).to eq(0)
    end

    # @spec NOTIFICATION-SEVERITY-011
    it "counts runner-scoped blocking notifications when the owner has a visible project" do
      project
      runner = user.runners.find_by!(runner_key: "claude", auth_type: "subscription")
      create(:notification, :error, account: account, subject: runner, blocking: true)

      expect(described_class.call(user: user)).to eq(1)
    end

    # @spec OPERATOR-INBOX-002B
    it "batch-preloads subject projects for action_required instead of querying per row" do
      create_agent_run_blocking_notification(github_number: 100)
      single_row_queries = count_queries { described_class.call(user: user) }

      create_agent_run_blocking_notification(github_number: 200)
      create_agent_run_blocking_notification(github_number: 300)
      multi_row_queries = count_queries { described_class.call(user: user) }

      expect(multi_row_queries).to eq(single_row_queries)
    end

    it "excludes ready PRs that have not yet been evaluated for auto-merge" do
      create(:issue, :pull_request, project: project)

      expect(described_class.call(user: user)).to eq(0)
    end

    it "excludes ready PRs on projects with auto-merge disabled" do
      disabled_project = create(
        :project,
        account: account,
        created_by: user,
        auto_pick_enabled: true,
        active: true,
        auto_merge_mode: "off",
        owner_reviewer_login: "viamin",
        owner: "acme",
        repo: "gamma"
      )
      create(
        :issue,
        :pull_request,
        project: disabled_project,
        auto_merge_evaluated_at: Time.current,
        auto_merge_blockers: approval_only_snapshot
      )

      expect(described_class.call(user: user)).to eq(0)
    end

    it "bumps the cache automatically when a PR enters or leaves the merge-approval queue" do
      pr = create(
        :issue,
        :pull_request,
        project: project,
        auto_merge_evaluated_at: Time.current,
        auto_merge_blockers: { "failed" => [], "not_evaluated" => [] }
      )
      first = described_class.call(user: user)

      pr.update!(awaiting_approval_since: 1.hour.ago, auto_merge_blockers: approval_only_snapshot)
      after_enter = described_class.call(user: user)

      pr.update!(auto_merge_blockers: { "failed" => [], "not_evaluated" => [] })
      after_exit = described_class.call(user: user)

      expect(first).to eq(0)
      expect(after_enter).to eq(1)
      expect(after_exit).to eq(0)
    end

    # @spec OPERATOR-INBOX-002C
    it "counts escalated pull requests on gated projects" do
      create_escalated_pr

      expect(described_class.call(user: user)).to eq(1)
    end

    # @spec OPERATOR-INBOX-002C
    it "excludes escalated pull requests on non-gated projects" do
      other_project = create(
        :project,
        account: account,
        created_by: user,
        auto_pick_enabled: false,
        active: true,
        owner: "acme",
        repo: "delta"
      )
      create(
        :issue,
        :pull_request,
        project: other_project,
        pr_review_phase: "escalated",
        pr_escalation_reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK
      )

      expect(described_class.call(user: user)).to eq(0)
    end

    # @spec OPERATOR-INBOX-002C
    it "bumps the cache automatically when a PR enters or leaves the escalated queue" do
      pr = create(:issue, :pull_request, project: project, pr_review_phase: "ready")
      first = described_class.call(user: user)

      pr.update!(pr_review_phase: "escalated", pr_escalation_reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK)
      after_escalate = described_class.call(user: user)

      pr.update!(pr_review_phase: "ready", pr_escalation_reason: nil)
      after_clear = described_class.call(user: user)

      expect(first).to eq(0)
      expect(after_escalate).to eq(1)
      expect(after_clear).to eq(0)
    end
  end

  def create_escalated_pr(github_number: 88, reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK, **attrs)
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: github_number,
      pr_review_phase: "escalated",
      pr_escalation_reason: reason,
      **attrs
    )
  end

  def create_agent_run_blocking_notification(github_number:)
    issue = create(:issue, project: project, github_number: github_number)
    agent_run = create(:agent_run, project: project, issue: issue)
    create(:notification, :error, account: account, subject: agent_run, blocking: true)
  end

  def create_merge_approval_pr
    create(
      :issue,
      :pull_request,
      project: project,
      auto_merge_evaluated_at: Time.current,
      awaiting_approval_since: 2.hours.ago,
      auto_merge_blockers: approval_only_snapshot
    )
  end

  def approval_only_snapshot
    {
      "failed" => [ {
        "signal" => "owner_approved",
        "status" => "failed",
        "reason_code" => "owner_approval_missing",
        "sanitized_message" => "Owner approval is missing.",
        "next_action" => "Ask the owner to approve."
      } ],
      "not_evaluated" => []
    }
  end
end
