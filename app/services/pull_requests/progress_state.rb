# frozen_string_literal: true

module PullRequests
  # Derives phase-agnostic PR automation progress from automatic create_pr and
  # review run history. Failure streaks reset only when the PR makes meaningful
  # progress or when an explicit reset marker is recorded on the issue.
  #
  # Reset conditions:
  # - a completed create_pr run
  # - a completed review run or a review run that posted a review
  # - a new PR HEAD commit (when the current head SHA is supplied, and
  #   head-commit time is known for failed runs without result_commit_sha)
  # - issue.review_goal_retry_reset_at
  # - issue.operational_failure_reset_at
  class ProgressState
    GOALS = %w[create_pr review].freeze
    RUN_BATCH_SIZE = 100
    RUN_TIMESTAMP_SQL = "COALESCE(completed_at, updated_at, created_at)".freeze

    Result = Data.define(
      :consecutive_unsuccessful_automatic_runs,
      :consecutive_operational_failures,
      :consecutive_provider_transient_outages,
      :last_meaningful_progress_at,
      :latest_automatic_run_at,
      :latest_unsuccessful_run_at,
      :latest_unsuccessful_run_goal,
      :latest_unsuccessful_run_status
    ) do
      # Returns true when every operational failure in the consecutive streak
      # is a purely transient provider outage (rate limits, circuit-open,
      # provider/runner exhaustion). These resolve on their own — no human
      # intervention is needed, so the escalation breaker should not fire.
      def all_provider_transient_outages?
        consecutive_operational_failures > 0 &&
          consecutive_provider_transient_outages >= consecutive_operational_failures
      end

      def escalation_worthy?(limit:)
        limit.to_i.positive? && consecutive_unsuccessful_automatic_runs >= limit.to_i
      end

      def retryable?(limit:)
        latest_unsuccessful_run_at.present? && !escalation_worthy?(limit:)
      end

      # A PR is "stuck" when its unified automatic-run failure streak has reached
      # the phase-appropriate limit AND that stuck state has been confirmed across
      # the required number of scan cycles. Confirmation is downtime-immune by
      # construction: scans only run while Paid is active, so wall-clock downtime
      # never advances the confirmation count. `confirmations` is the persisted
      # per-issue scan count (see ScanPaidPrsActivity#update_stuck_confirmation!).
      def stuck?(limit:, confirmations:, required_confirmations:)
        return false unless escalation_worthy?(limit:)
        return false if latest_unsuccessful_run_at.blank?
        return false if required_confirmations.to_i <= 0

        confirmations.to_i >= required_confirmations.to_i
      end

      def latest_unsuccessful_review?
        latest_unsuccessful_run_goal == "review"
      end
    end

    def self.call(...)
      new(...).call
    end

    # current_head_updated_at is the current PR head commit timestamp, not the
    # pull request's generic updated_at. Failed runs without result_commit_sha
    # need actual head-commit recency to decide whether a human push
    # superseded them.
    def initialize(project:, issue:, runs: nil, current_head_sha: nil, current_head_updated_at: nil)
      @project = project
      @issue = issue
      @runs = runs
      @current_head_sha = current_head_sha
      @current_head_updated_at = current_head_updated_at
    end

    def call
      explicit_reset_at = reset_markers.compact.max
      progress_at = explicit_reset_at
      failure_streak = 0
      operational_streak = nil
      transient_in_op_streak = 0
      latest_failure = nil
      latest_automatic_run_at = nil

      each_relevant_run(explicit_reset_at:) do |run|
        run_time = run_timestamp(run)
        latest_automatic_run_at ||= run_time if automatic_pr_run?(run)

        if superseded_by_new_head?(run)
          progress_at = [ progress_at, current_head_updated_at ].compact.max
          break
        end

        if meaningful_progress?(run)
          progress_at = [ progress_at, progress_timestamp(run) ].compact.max
          break
        end

        break if streak_boundary?(run)

        next unless unsuccessful?(run)

        latest_failure ||= run
        failure_streak += 1

        if operational_streak.nil?
          operational_streak = run.operational_failure? ? 1 : 0
          transient_in_op_streak = (run.operational_failure? && run.provider_unavailable?) ? 1 : 0
        elsif operational_streak.positive? && run.operational_failure?
          operational_streak += 1
          transient_in_op_streak += 1 if run.provider_unavailable?
        end
      end

      Result.new(
        consecutive_unsuccessful_automatic_runs: failure_streak,
        consecutive_operational_failures: operational_streak || 0,
        consecutive_provider_transient_outages: transient_in_op_streak,
        last_meaningful_progress_at: progress_at,
        latest_automatic_run_at: latest_automatic_run_at,
        latest_unsuccessful_run_at: latest_failure && run_timestamp(latest_failure),
        latest_unsuccessful_run_goal: latest_failure&.goal,
        latest_unsuccessful_run_status: latest_failure&.status
      )
    end

    private

    attr_reader :project, :issue, :runs, :current_head_sha, :current_head_updated_at

    def each_relevant_run(explicit_reset_at:, &block)
      return enum_for(__method__, explicit_reset_at:) unless block

      if runs
        ordered_supplied_runs.each do |run|
          boundary_time = explicit_reset_boundary_time(run)
          next if explicit_reset_at && boundary_time && boundary_time <= explicit_reset_at

          yield run
        end
      else
        each_loaded_run(explicit_reset_at:, &block)
      end
    end

    def ordered_supplied_runs
      @ordered_supplied_runs ||= Array(runs)
        .compact
        .sort_by { |run| [ run_timestamp(run) || Time.at(0), run.created_at || Time.at(0) ] }
        .reverse
    end

    def each_loaded_run(explicit_reset_at:)
      offset = 0

      loop do
        batch = ordered_run_scope.limit(RUN_BATCH_SIZE).offset(offset).to_a
        break if batch.empty?

        batch.each do |run|
          boundary_time = explicit_reset_boundary_time(run)
          next if explicit_reset_at && boundary_time && boundary_time <= explicit_reset_at

          yield run
        end

        break if batch.length < RUN_BATCH_SIZE

        offset += RUN_BATCH_SIZE
      end
    end

    def load_runs
      project.agent_runs
        .where(goal: GOALS)
        .where(
          "issue_id = :issue_id OR source_pull_request_number = :pr_num OR pull_request_number = :pr_num",
          issue_id: issue.id,
          pr_num: issue.github_number
        )
        .finished
        .where.not(status: "retried")
    end

    def ordered_run_scope
      @ordered_run_scope ||= load_runs.order(
        Arel.sql("#{RUN_TIMESTAMP_SQL} DESC, created_at DESC, id DESC")
      )
    end

    def reset_markers
      [
        issue.review_goal_retry_reset_at,
        issue.operational_failure_reset_at
      ]
    end

    # Explicit reset markers start a new automation cycle. Runs that began
    # before the reset should not affect the new cycle even if they finished
    # afterward, so prefer the earliest available start/create timestamp here.
    def explicit_reset_boundary_time(run)
      boundary_candidates = [ run.respond_to?(:started_at) ? run.started_at : nil, run.created_at ].compact
      boundary_candidates.min || run_timestamp(run)
    end

    def superseded_by_new_head?(run)
      return false if current_head_sha.blank?

      # Compare against result_commit_sha (the HEAD after the agent finished
      # and pushed). base_commit_sha stores the merge-base against the default
      # branch for existing-PR runs, not the PR head SHA.
      #
      # When result_commit_sha is present, compare it directly to current_head_sha.
      # When result_commit_sha is nil (e.g. a failed run that never pushed),
      # fall back to checking whether the PR head commit happened after the run
      # completed — a human follow-up commit supersedes the stale failure.
      if run.result_commit_sha.present?
        return run.result_commit_sha != current_head_sha
      end

      current_head_updated_at.present? && run_timestamp(run).present? &&
        current_head_updated_at > run_timestamp(run)
    end

    def meaningful_progress?(run)
      return false unless pr_run?(run)

      create_pr_progress?(run) || review_progress?(run)
    end

    def unsuccessful?(run)
      automatic_pr_run?(run) && run.finished? && !meaningful_progress?(run)
    end

    def streak_boundary?(run)
      pr_run?(run) && run.finished? && !automatic_pr_run?(run)
    end

    def automatic_pr_run?(run)
      run.trigger_type == "automatic" && run.goal.in?(GOALS)
    end

    def pr_run?(run)
      run.goal.in?(GOALS)
    end

    def create_pr_progress?(run)
      run.goal == "create_pr" && run.status == "completed"
    end

    def review_progress?(run)
      run.goal == "review" && (run.status == "completed" || run.review_posted_at.present?)
    end

    def progress_timestamp(run)
      return run.review_posted_at if run.goal == "review" && run.review_posted_at.present?

      run_timestamp(run)
    end

    def run_timestamp(run)
      run.completed_at || run.updated_at || run.created_at
    end
  end
end
