# frozen_string_literal: true

module Dashboard
  # Open pull requests Paid has stopped working, with the numbers that stopped
  # them. Reads issue state directly — it surfaces the escalated phase, it does
  # not decide what counts as blocked.
  #
  # @spec PR-ESCALATION-011 @spec PR-ESCALATION-012 @spec PR-ESCALATION-013
  class BlockedPullRequests
    Counter = Data.define(:name, :value, :limit)

    Entry = Data.define(
      :pull_request,
      :reason,
      :blocked_since,
      :counters,
      :last_progress_at,
      :operator_paused
    )

    def self.call(...) = new(...).call

    def initialize(account:)
      @account = account
    end

    def call
      blocked = blocked_scope.to_a
      runs = operational_failure_runs(blocked)
      blocked.map { |pull_request| build_entry(pull_request, runs) }
    end

    private

    attr_reader :account

    def blocked_scope
      Issue.joins(:project)
        .where(projects: { account_id: account.id })
        .where(is_pull_request: true, github_state: "open", pr_review_phase: "escalated")
        .excluding_body
        .preload(project: { account: :tenant_setting })
        .order(updated_at: :asc)
    end

    def build_entry(pull_request, runs_pool)
      Entry.new(
        pull_request: pull_request,
        reason: pull_request.pr_escalation_reason,
        blocked_since: pull_request.updated_at,
        counters: tripped_counters(pull_request),
        last_progress_at: last_progress_at(pull_request, runs_pool),
        operator_paused: pull_request.auto_continue_paused?
      )
    end

    # A reason does not map to one counter: failure_streak is tripped by either
    # the draft-round or the follow-up counter, and an operational escalation
    # has neither. Report every counter that is at or over its limit and let the
    # surface show them all.
    def tripped_counters(pull_request)
      project = pull_request.project

      candidates = [
        Counter.new(name: :draft_review_count,
          value: pull_request.draft_review_count.to_i,
          limit: project.max_draft_review_rounds.to_i),
        Counter.new(name: :pr_followup_count,
          value: pull_request.pr_followup_count.to_i,
          limit: project.max_pr_followup_runs.to_i),
        Counter.new(name: :review_goal_retry_count,
          value: pull_request.review_goal_retry_count.to_i,
          limit: review_goal_retry_limit(project))
      ]

      candidates.select { |counter| counter.limit.positive? && counter.value >= counter.limit }
    end

    # Mirrors ScanPaidPrsActivity#review_goal_max_retries: the configured retry
    # budget, capped by the review-round limit when one is set.
    def review_goal_retry_limit(project)
      method_config = project.review_method(:paid_agent)
      retries = method_config.max_review_goal_retries
      max_rounds = method_config.max_review_rounds

      effective = retries.present? ? retries.to_i : Activities::ScanPaidPrsActivity::MAX_REVIEW_GOAL_RETRIES
      max_rounds.present? ? [ effective, max_rounds.to_i ].min : effective
    end

    def last_progress_at(pull_request, runs_pool)
      return nil unless pull_request.pr_escalation_reason == Issue::PR_ESCALATION_REASON_OPERATIONAL_FAILURES

      pull_request.last_pr_meaningful_progress_at(runs: runs_for(pull_request, runs_pool))
    end

    # ponytail: batched equivalent of AgentRun.pr_history_scope + ProgressState's
    # load_runs filters — keep the predicate in sync with those two.
    OPERATIONAL_RUN_SQL = (
      "(agent_runs.project_id = ? AND " \
      "(agent_runs.issue_id = ? OR agent_runs.source_pull_request_number = ? OR agent_runs.pull_request_number = ?))"
    ).freeze

    def operational_failure_runs(blocked)
      operational = blocked.select { |pr| pr.pr_escalation_reason == Issue::PR_ESCALATION_REASON_OPERATIONAL_FAILURES }
      return [] if operational.empty?

      AgentRun.where(goal: PullRequests::ProgressState::GOALS)
        .finished
        .where.not(status: "retried")
        .where(
          [ operational.map { OPERATIONAL_RUN_SQL }.join(" OR "),
            *operational.flat_map { |pr| [ pr.project_id, pr.id, pr.github_number, pr.github_number ] } ]
        )
        .to_a
    end

    def runs_for(pull_request, pool)
      pool.select do |run|
        run.project_id == pull_request.project_id &&
          (run.issue_id == pull_request.id ||
            run.source_pull_request_number == pull_request.github_number ||
            run.pull_request_number == pull_request.github_number)
      end
    end
  end
end
