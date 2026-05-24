# frozen_string_literal: true

module Notifications
  module Rules
    class StalledDraftPr < Rule
      SOURCE = "stalled_draft_pr"
      NO_PROGRESS_ESCALATION_WINDOW = Activities::ScanPaidPrsActivity::NO_PROGRESS_ESCALATION_WINDOW
      ERROR_THRESHOLD = 10

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
        return false unless synced_with_latest_pr_state?(issue)

        progress_state_for(issue).stuck?(limit: issue.project.max_draft_review_rounds,
          stale_after: NO_PROGRESS_ESCALATION_WINDOW)
      end

      def build(issue)
        progress_state = progress_state_for(issue)
        failures = progress_state.consecutive_unsuccessful_automatic_runs

        {
          severity: failures >= ERROR_THRESHOLD ? :error : :warning,
          title: "PR ##{issue.github_number} stuck in #{issue.pr_review_phase} for #{human_duration(stall_since(issue))}",
          description: description_for(issue, progress_state, failures),
          nav_section: "projects",
          action_url: project_path(issue.project),
          metadata: {
            consecutive_failures: failures,
            latest_unsuccessful_run_at: progress_state.latest_unsuccessful_run_at&.iso8601,
            latest_unsuccessful_run_goal: progress_state.latest_unsuccessful_run_goal,
            latest_unsuccessful_run_status: progress_state.latest_unsuccessful_run_status
          }.compact
        }
      end

      def description_for(issue, progress_state, failures)
        parts = []
        parts << "#{failures} consecutive unsuccessful automatic PR runs" if failures.positive?
        if progress_state.latest_unsuccessful_run_goal.present? && progress_state.latest_unsuccessful_run_status.present?
          parts << "latest run: #{progress_state.latest_unsuccessful_run_goal} #{progress_state.latest_unsuccessful_run_status}"
        end
        parts.join(". ")
      end

      def stall_since(issue)
        progress_state = progress_state_for(issue)
        progress_state.last_meaningful_progress_at || progress_state.latest_unsuccessful_run_at || issue.github_updated_at || issue.created_at
      end

      def resolve_candidates(scope)
        Array(scope).select do |issue|
          issue.github_state != "open" ||
            !issue.pr_review_phase.in?(%w[draft restarted]) ||
            synced_with_latest_pr_state?(issue)
        end
      end

      def synced_with_latest_pr_state?(issue)
        return false if issue.last_pr_scan_at.blank?
        return true if issue.github_updated_at.blank?

        issue.last_pr_scan_at >= issue.github_updated_at
      end

      def progress_state_for(issue)
        @progress_states ||= {}
        @progress_states[issue.id] ||= issue.pr_progress_state
      end
    end
  end
end
