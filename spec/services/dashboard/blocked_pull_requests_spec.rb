# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::BlockedPullRequests do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) do
    create(:project,
      account: account,
      created_by: user,
      owner: "acme",
      repo: "alpha",
      max_draft_review_rounds: 10,
      max_pr_followup_runs: 8)
  end

  def escalated_pr(number:, reason:, **attrs)
    create(:issue, :pull_request,
      project: project,
      github_number: number,
      pr_review_phase: "escalated",
      pr_escalation_reason: reason,
      labels: [ "paid-generated", "paid-automation", "paid-escalated" ],
      **attrs)
  end

  # @spec PR-ESCALATION-011
  it "lists escalated open pull requests for the account, longest-stopped first" do
    recent = escalated_pr(number: 2, reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK,
      draft_review_count: 10, pr_escalation_started_at: 2.hours.ago)
    # No start marker: escalations that predate the column fall back to
    # updated_at for both the sort and the displayed age.
    middle = escalated_pr(number: 3, reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK,
      draft_review_count: 10)
    middle.update_column(:updated_at, 30.hours.ago)
    older = escalated_pr(number: 1, reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK,
      draft_review_count: 12, pr_escalation_started_at: 3.days.ago)

    entries = described_class.call(account: account)

    expect(entries.map(&:pull_request)).to eq([ older, middle, recent ])
    expect(entries.first.reason).to eq(Issue::PR_ESCALATION_REASON_FAILURE_STREAK)
    expect(entries.first.blocked_since).to be_within(1.minute).of(3.days.ago)
  end

  # @spec PR-ESCALATION-011
  it "keeps the stopped age stable when unrelated writes touch the PR" do
    pull_request = escalated_pr(number: 1,
      reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK,
      draft_review_count: 10,
      pr_escalation_started_at: 2.days.ago)
    # Label syncs and the escalation-label reapply bump updated_at without
    # changing when the PR stopped.
    pull_request.update_column(:updated_at, 5.minutes.ago)

    entry = described_class.call(account: account).first

    expect(entry.blocked_since).to be_within(1.minute).of(2.days.ago)
  end

  # @spec PR-ESCALATION-011
  it "excludes closed pull requests, non-escalated pull requests, and other accounts" do
    escalated_pr(number: 1, reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK, draft_review_count: 10)
    escalated_pr(number: 2, reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK,
      draft_review_count: 10, github_state: "closed")
    create(:issue, :pull_request, project: project, github_number: 3, pr_review_phase: "ready")

    other_project = create(:project, account: create(:account), owner: "other", repo: "beta")
    create(:issue, :pull_request,
      project: other_project,
      github_number: 4,
      pr_review_phase: "escalated",
      pr_escalation_reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK)

    entries = described_class.call(account: account)

    expect(entries.map { |entry| entry.pull_request.github_number }).to eq([ 1 ])
  end

  describe "counters" do
    # @spec PR-ESCALATION-012
    it "reports every counter that has reached its configured limit" do
      escalated_pr(number: 1,
        reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK,
        draft_review_count: 12,
        pr_followup_count: 8)

      entry = described_class.call(account: account).first

      expect(entry.counters).to contain_exactly(
        having_attributes(name: :draft_review_count, value: 12, limit: 10),
        having_attributes(name: :pr_followup_count, value: 8, limit: 8)
      )
    end

    # @spec PR-ESCALATION-012
    it "omits counters that are below their limit" do
      escalated_pr(number: 1,
        reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK,
        draft_review_count: 12,
        pr_followup_count: 2)

      entry = described_class.call(account: account).first

      expect(entry.counters.map(&:name)).to eq([ :draft_review_count ])
    end

    # @spec PR-ESCALATION-012
    it "reports time since meaningful progress for an operational escalation" do
      pull_request = escalated_pr(number: 1,
        reason: Issue::PR_ESCALATION_REASON_OPERATIONAL_FAILURES)
      # Real run history so the batched progress query is actually exercised
      # rather than stubbed away.
      create(:agent_run,
        project: project,
        issue: pull_request,
        source_pull_request_number: pull_request.github_number,
        goal: "create_pr",
        trigger_type: "automatic",
        status: "completed",
        result_commit_sha: "abc123",
        completed_at: 6.hours.ago)

      entry = described_class.call(account: account).first

      expect(entry.pull_request).to eq(pull_request)
      expect(entry.counters).to be_empty
      expect(entry.last_progress_at).to be_within(5.minutes).of(6.hours.ago)
    end
  end

  describe "operator pause" do
    # @spec PR-ESCALATION-013
    it "excludes pull requests held only by the operator pause" do
      create(:issue, :pull_request,
        project: project,
        github_number: 1,
        pr_review_phase: "ready",
        auto_continue_paused: true)

      expect(described_class.call(account: account)).to be_empty
    end

    # @spec PR-ESCALATION-013
    it "flags a listed pull request that is also operator-paused" do
      escalated_pr(number: 1,
        reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK,
        draft_review_count: 10,
        auto_continue_paused: true)
      escalated_pr(number: 2,
        reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK,
        draft_review_count: 10)

      entries = described_class.call(account: account).index_by { |entry| entry.pull_request.github_number }

      expect(entries[1].operator_paused).to be(true)
      expect(entries[2].operator_paused).to be(false)
    end
  end
end
