# frozen_string_literal: true

module PullRequests
  # Derives phase-agnostic PR automation progress from automatic create_pr and
  # review run history. Failure streaks reset only when the PR makes meaningful
  # progress or when an explicit reset marker is recorded on the issue.
  #
  # Reset conditions:
  # - a completed automatic create_pr run
  # - an automatic review run that posted a review
  # - issue.review_goal_retry_reset_at
  # - issue.operational_failure_reset_at
  class ProgressState
    GOALS = %w[create_pr review].freeze

    Result = Data.define(
      :consecutive_unsuccessful_automatic_runs,
      :consecutive_operational_failures,
      :last_meaningful_progress_at,
      :latest_automatic_run_at,
      :latest_unsuccessful_run_at,
      :latest_unsuccessful_run_goal,
      :latest_unsuccessful_run_status
    ) do
      def escalation_worthy?(limit:)
        limit.to_i.positive? && consecutive_unsuccessful_automatic_runs >= limit.to_i
      end

      def retryable?(limit:)
        latest_unsuccessful_run_at.present? && !escalation_worthy?(limit:)
      end

      def stuck?(limit:, stale_after:)
        return false unless escalation_worthy?(limit:)
        return false if latest_unsuccessful_run_at.blank?
        return false if stale_after.to_i <= 0

        progress_at = last_meaningful_progress_at || Time.at(0)
        progress_at <= stale_after.to_i.seconds.ago
      end

      def latest_unsuccessful_review?
        latest_unsuccessful_run_goal == "review"
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue:, runs: nil)
      @project = project
      @issue = issue
      @runs = runs
    end

    def call
      explicit_reset_at = reset_markers.compact.max
      progress_at = explicit_reset_at
      failure_streak = 0
      operational_streak = nil
      latest_failure = nil

      relevant_runs.each do |run|
        run_time = run_timestamp(run)
        next if explicit_reset_at && run_time && run_time <= explicit_reset_at

        if meaningful_progress?(run)
          progress_at = [ progress_at, progress_timestamp(run) ].compact.max
          break
        end

        next unless unsuccessful?(run)

        latest_failure ||= run
        failure_streak += 1

        if operational_streak.nil?
          operational_streak = run.operational_failure? ? 1 : 0
        elsif operational_streak.positive? && run.operational_failure?
          operational_streak += 1
        end
      end

      Result.new(
        consecutive_unsuccessful_automatic_runs: failure_streak,
        consecutive_operational_failures: operational_streak || 0,
        last_meaningful_progress_at: progress_at,
        latest_automatic_run_at: relevant_runs.first && run_timestamp(relevant_runs.first),
        latest_unsuccessful_run_at: latest_failure && run_timestamp(latest_failure),
        latest_unsuccessful_run_goal: latest_failure&.goal,
        latest_unsuccessful_run_status: latest_failure&.status
      )
    end

    private

    attr_reader :project, :issue, :runs

    def relevant_runs
      @relevant_runs ||= Array(runs || load_runs)
        .compact
        .sort_by { |run| [ run_timestamp(run) || Time.at(0), run.created_at || Time.at(0) ] }
        .reverse
    end

    def load_runs
      project.agent_runs
        .where(goal: GOALS, trigger_type: "automatic")
        .where(
          "source_pull_request_number = :pr_num OR pull_request_number = :pr_num",
          pr_num: issue.github_number
        )
        .finished
        .where.not(status: "retried")
    end

    def reset_markers
      [
        issue.review_goal_retry_reset_at,
        issue.operational_failure_reset_at
      ]
    end

    def meaningful_progress?(run)
      return false unless automatic_pr_run?(run)

      create_pr_progress?(run) || review_progress?(run)
    end

    def unsuccessful?(run)
      automatic_pr_run?(run) && run.finished? && !meaningful_progress?(run)
    end

    def automatic_pr_run?(run)
      run.trigger_type == "automatic" && run.goal.in?(GOALS)
    end

    def create_pr_progress?(run)
      run.goal == "create_pr" && run.status == "completed"
    end

    def review_progress?(run)
      run.goal == "review" && run.review_posted_at.present?
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
