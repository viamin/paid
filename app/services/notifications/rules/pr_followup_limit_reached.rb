# frozen_string_literal: true

module Notifications
  module Rules
    class PrFollowupLimitReached < Rule
      SOURCE = "pr_followup_limit_reached"
      NO_PROGRESS_ESCALATION_WINDOW = Activities::ScanPaidPrsActivity::NO_PROGRESS_ESCALATION_WINDOW

      def initialize(progress_states: nil)
        @progress_states = index_progress_states(progress_states)
      end

      private

      attr_reader :progress_states

      def source = SOURCE

      def detect(scope)
        Array(scope).select do |issue|
          issue.is_pull_request? &&
            issue.github_state == "open" &&
            issue.pr_review_phase.in?(%w[ready escalated]) &&
            synced_with_latest_pr_state?(issue) &&
            !progress_state_for(issue).latest_unsuccessful_review? &&
            progress_state_for(issue).stuck?(limit: issue.project.max_pr_followup_runs, stale_after: NO_PROGRESS_ESCALATION_WINDOW)
        end
      end

      def build(issue)
        count = progress_state_for(issue).consecutive_unsuccessful_automatic_runs
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

      def resolve_candidates(scope)
        Array(scope).select do |issue|
          issue.github_state != "open" ||
            !issue.pr_review_phase.in?(%w[ready escalated]) ||
            synced_with_latest_pr_state?(issue)
        end
      end

      def synced_with_latest_pr_state?(issue)
        return false if issue.last_pr_scan_at.blank?
        return true if issue.github_updated_at.blank?

        issue.last_pr_scan_at >= issue.github_updated_at
      end

      def progress_state_for(issue)
        progress_states.fetch(progress_state_key(issue.id)) { issue.pr_progress_state }
      end

      def index_progress_states(progress_states)
        Array(progress_states).each_with_object({}) do |entry, indexed|
          next unless entry.is_a?(Hash)

          issue_id = entry[:issue_id] || entry["issue_id"]
          next if issue_id.blank?

          indexed[progress_state_key(issue_id)] = PullRequests::ProgressState::Result.new(
            consecutive_unsuccessful_automatic_runs: entry[:consecutive_unsuccessful_automatic_runs] || entry["consecutive_unsuccessful_automatic_runs"] || 0,
            consecutive_operational_failures: entry[:consecutive_operational_failures] || entry["consecutive_operational_failures"] || 0,
            last_meaningful_progress_at: entry[:last_meaningful_progress_at] || entry["last_meaningful_progress_at"],
            latest_automatic_run_at: entry[:latest_automatic_run_at] || entry["latest_automatic_run_at"],
            latest_unsuccessful_run_at: entry[:latest_unsuccessful_run_at] || entry["latest_unsuccessful_run_at"],
            latest_unsuccessful_run_goal: entry[:latest_unsuccessful_run_goal] || entry["latest_unsuccessful_run_goal"],
            latest_unsuccessful_run_status: entry[:latest_unsuccessful_run_status] || entry["latest_unsuccessful_run_status"]
          )
        end
      end

      def progress_state_key(issue_id)
        issue_id.to_s
      end
    end
  end
end
