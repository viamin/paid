# frozen_string_literal: true

module Notifications
  module Rules
    class RepeatedNoChanges < Rule
      SOURCE = "repeated_no_changes"
      THRESHOLD = 3

      private

      def source = SOURCE

      def detect(scope)
        Array(scope).filter_map do |issue|
          next if issue.is_pull_request?
          next unless issue.github_state == "open"

          latest_run = latest_finished_run(issue)
          next unless latest_run&.status == "no_output" && latest_run.error_message == "no_changes"

          state = update_state!(issue, latest_run)
          issue if state.metadata["consecutive_runs"].to_i >= THRESHOLD
        end
      end

      def resolve_candidates(scope)
        Array(scope).reject(&:is_pull_request?)
      end

      def build(issue)
        metadata = state_metadata_for(issue)

        {
          severity: :info,
          title: "Issue ##{issue.github_number} completed with no changes #{metadata[:consecutive_runs]} times",
          description: "The latest #{metadata[:consecutive_runs]} finished runs ended with no_changes.",
          nav_section: "agent_runs",
          action_url: project_agent_runs_path(issue.project),
          metadata: {
            consecutive_runs: metadata[:consecutive_runs].to_i,
            latest_run_id: metadata[:latest_run_id]
          }
        }
      end

      def update_state!(issue, latest_run)
        metadata = state_metadata_for(issue)
        previous_run_completed_at = parse_time(metadata[:latest_run_completed_at])
        issue_updated_at = issue.github_updated_at

        streak_continues = metadata[:latest_run_id].present? &&
          metadata[:latest_run_id].to_i != latest_run.id &&
          previous_run_completed_at.present? &&
          issue_updated_at.present? &&
          issue_updated_at <= previous_run_completed_at

        consecutive_runs = streak_continues ? metadata[:consecutive_runs].to_i + 1 : 1
        first_seen_at = streak_continues ? parse_time(metadata[:first_seen_at]) || Time.current : Time.current

        save_state!(
          issue,
          first_seen_at: first_seen_at,
          last_seen_at: latest_run.completed_at || Time.current,
          metadata: {
            consecutive_runs: consecutive_runs,
            latest_run_id: latest_run.id,
            latest_run_completed_at: latest_run.completed_at&.iso8601,
            first_seen_at: first_seen_at.iso8601
          }
        )
      end

      def latest_finished_run(issue)
        @latest_finished_runs ||= {}
        @latest_finished_runs[issue.id] ||= issue.agent_runs.finished.order(created_at: :desc).first
      end
    end
  end
end
