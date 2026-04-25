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
            issue.pr_followup_count >= issue.project.max_pr_followup_runs
        end
      end

      def build(issue)
        {
          severity: :info,
          title: "PR ##{issue.github_number} hit the follow-up limit",
          description: "#{issue.pr_followup_count}/#{issue.project.max_pr_followup_runs} follow-up runs have been consumed.",
          nav_section: "projects",
          action_url: project_path(issue.project),
          metadata: {
            pr_followup_count: issue.pr_followup_count,
            max_pr_followup_runs: issue.project.max_pr_followup_runs
          }
        }
      end
    end
  end
end
