# frozen_string_literal: true

module Notifications
  module Rules
    class StalledDraftPr < Rule
      SOURCE = "stalled_draft_pr"
      FAILURE_STATUSES = %w[timeout failed cancelled auth_expired rate_limited].freeze
      FAILURE_THRESHOLD = 3
      ERROR_THRESHOLD = 10
      STALL_THRESHOLD = 6.hours

      private

      def source = SOURCE

      def detect(scope)
        Array(scope).select { |issue| stalled?(issue) }
      end

      def stalled?(issue)
        return false unless issue.is_pull_request?
        return false unless issue.github_state == "open"
        return false unless issue.pr_review_phase.in?(%w[draft restarted])
        return false if issue.auto_continue_paused?

        consecutive_failures(issue) >= FAILURE_THRESHOLD || stalled_duration(issue) >= STALL_THRESHOLD
      end

      def build(issue)
        latest_run = latest_draft_followup_run(issue)
        failures = consecutive_failures(issue)

        {
          severity: failures >= ERROR_THRESHOLD ? :error : :warning,
          title: "PR ##{issue.github_number} stuck in draft for #{human_duration(stall_since(issue))}",
          description: description_for(issue, latest_run, failures),
          nav_section: "projects",
          action_url: project_path(issue.project),
          metadata: {
            consecutive_failures: failures,
            latest_run_id: latest_run&.id,
            earliest_failure_at: earliest_failure_at(issue)&.iso8601
          }.compact
        }
      end

      def description_for(issue, latest_run, failures)
        parts = []
        parts << "#{failures} consecutive failed draft follow-ups" if failures.positive?
        parts << "latest error: #{latest_run.error_message}" if latest_run&.error_message.present?
        parts << "latest run: #{project_agent_run_path(issue.project, latest_run)}" if latest_run
        parts.join(". ")
      end

      def stalled_duration(issue)
        since = stall_since(issue)
        return 0 unless since

        Time.current - since
      end

      def stall_since(issue)
        last_progress_run(issue)&.completed_at || earliest_failure_at(issue) || issue.github_updated_at || issue.created_at
      end

      def earliest_failure_at(issue)
        failure_streak(issue).last&.created_at
      end

      def consecutive_failures(issue)
        failure_streak(issue).size
      end

      def failure_streak(issue)
        @failure_streaks ||= {}
        @failure_streaks[issue.id] ||= draft_followup_runs(issue).take_while { |run| FAILURE_STATUSES.include?(run.status) }
      end

      def latest_draft_followup_run(issue)
        draft_followup_runs(issue).first
      end

      def last_progress_run(issue)
        draft_followup_runs(issue).find { |run| run.status.in?(%w[completed no_output]) }
      end

      def draft_followup_runs(issue)
        @draft_followup_runs ||= {}
        @draft_followup_runs[issue.id] ||= issue.project.agent_runs
          .where(source_pull_request_number: issue.github_number, trigger_type: "automatic", goal: "create_pr")
          .where(count_toward_draft_review_round: true)
          .finished
          .order(created_at: :desc)
          .limit(ERROR_THRESHOLD)
          .to_a
      end
    end
  end
end
