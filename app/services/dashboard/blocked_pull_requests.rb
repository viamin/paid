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

    def initialize(account:, pull_request_id: nil)
      @account = account
      @pull_request_id = pull_request_id
    end

    def call
      blocked = blocked_scope.to_a
      runs = operational_failure_runs(blocked)
      token_usage = token_usage_by_pull_request(blocked)
      blocked.map { |pull_request| build_entry(pull_request, runs, token_usage) }
    end

    private

    attr_reader :account

    def blocked_scope
      Issue.joins(:project)
        .then { |scope| @pull_request_id ? scope.where(id: @pull_request_id) : scope }
        .where(projects: { account_id: account.id })
        .where(is_pull_request: true, github_state: "open", pr_review_phase: "escalated")
        .excluding_body
        .preload(project: { account: :tenant_setting })
        # `updated_at` is a shared touch timestamp — label syncs and the
        # escalation-label reapply bump it without changing when the PR
        # stopped — so age and ordering follow the escalation-start marker,
        # falling back for escalations that predate the column.
        .order(Arel.sql("COALESCE(issues.pr_escalation_started_at, issues.updated_at) ASC"))
    end

    def build_entry(pull_request, runs_pool, token_usage)
      Entry.new(
        pull_request: pull_request,
        reason: pull_request.pr_escalation_reason,
        blocked_since: pull_request.pr_escalation_started_at || pull_request.updated_at,
        counters: tripped_counters(pull_request, token_usage.fetch(pull_request.id, 0)),
        last_progress_at: last_progress_at(pull_request, runs_pool),
        operator_paused: pull_request.auto_continue_paused?
      )
    end

    # A reason does not map to one counter: failure_streak is tripped by either
    # the draft-round or the follow-up counter, and an operational escalation
    # has neither. Report every counter that is at or over its limit and let the
    # surface show them all.
    def tripped_counters(pull_request, tokens_used)
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

      candidates << token_counter(pull_request, tokens_used)
      candidates.compact.select { |counter| counter.limit.positive? && counter.value >= counter.limit }
    end

    # @spec PR-ESCALATION-007
    def token_counter(pull_request, tokens_used)
      return unless pull_request.pr_escalation_reason == Issue::PR_ESCALATION_REASON_PR_AUTO_CONTINUE_TOKEN_LIMIT

      Counter.new(
        name: :pr_auto_continue_tokens,
        value: tokens_used,
        limit: pull_request.pr_auto_continue_token_limit_effective_limit(
          pull_request.project.max_pr_auto_continue_tokens
        )
      )
    end

    def token_usage_by_pull_request(blocked)
      token_limited = blocked.select do |pull_request|
        pull_request.pr_escalation_reason == Issue::PR_ESCALATION_REASON_PR_AUTO_CONTINUE_TOKEN_LIMIT
      end
      return {} if token_limited.empty?

      targets = token_usage_targets(token_limited)
      token_usage_runs(token_limited).each_with_object(Hash.new(0)) do |run, usage|
        target = targets[run.issue_id] ||
          targets[[ run.project_id, run.source_pull_request_number ]] ||
          targets[[ run.project_id, run.pull_request_number ]]
        usage[target] += run.tokens_input.to_i + run.tokens_output.to_i if target
      end
    end

    def token_usage_targets(pull_requests)
      pull_requests.each_with_object({}) do |pull_request, targets|
        targets[pull_request.id] = pull_request.id
        targets[[ pull_request.project_id, pull_request.github_number ]] = pull_request.id
      end
    end

    def token_usage_runs(pull_requests)
      clauses = pull_requests.map { "(agent_runs.issue_id = ? OR agent_runs.source_pull_request_number = ? OR agent_runs.pull_request_number = ?)" }
      bindings = pull_requests.flat_map { |pull_request| [ pull_request.id, pull_request.github_number, pull_request.github_number ] }

      AgentRun.where(project_id: pull_requests.map(&:project_id), trigger_type: "automatic")
        .where([ clauses.join(" OR "), *bindings ])
        .select(:project_id, :issue_id, :source_pull_request_number, :pull_request_number, :tokens_input, :tokens_output)
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

      # Slim columns only: ProgressState reads status/goal/timestamps/shas
      # from these runs, never the transcript or diagnostic payloads.
      AgentRun.where(goal: PullRequests::ProgressState::GOALS)
        .finished
        .where.not(status: "retried")
        .excluding_list_payload
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
