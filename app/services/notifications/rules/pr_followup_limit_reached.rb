# frozen_string_literal: true

module Notifications
  module Rules
    class PrFollowupLimitReached < Rule
      SOURCE = "pr_followup_limit_reached"

      private

      def source = SOURCE

      def detect(scope)
        Array(scope).select do |issue|
          issue.is_pull_request? &&
            issue.github_state == "open" &&
            issue.pr_review_phase.in?(%w[ready escalated]) &&
            synced_with_latest_pr_state?(issue) &&
            issue.pr_escalation_worthy?(limit: issue.project.max_pr_followup_runs)
        end
      end

      def build(issue)
        count = issue.consecutive_unsuccessful_pr_runs
        limit = issue.project.max_pr_followup_runs
        {
          severity: :info,
          title: "PR ##{issue.github_number} hit the follow-up limit",
          description: "#{count}/#{limit} consecutive unsuccessful automatic PR runs.",
          nav_section: "projects",
          action_url: project_path(issue.project),
          metadata: {
            consecutive_unsuccessful_automatic_runs: count,
            max_pr_followup_runs: limit
          }
        }
      end

      def synced_with_latest_pr_state?(issue)
        issue.last_pr_scan_at.present? && issue.last_pr_scan_at > issue.github_updated_at
      end
    end
  end
end
