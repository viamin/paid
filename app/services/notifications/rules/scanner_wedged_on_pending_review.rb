# frozen_string_literal: true

module Notifications
  module Rules
    class ScannerWedgedOnPendingReview < Rule
      SOURCE = "scanner_wedged_on_pending_review"
      THRESHOLD = 4
      WINDOW = 1.hour

      private

      def source = SOURCE

      def detect(scope)
        scoped_issues(scope).filter_map do |issue, entry|
          next unless issue.github_state == "open"
          next unless issue.pr_review_phase.in?(%w[draft restarted])
          next if issue.auto_continue_paused?
          next unless entry[:pending_review]

          state = update_state!(issue, entry)
          issue if state.metadata["consecutive_polls"].to_i >= THRESHOLD
        end
      end

      def resolve_candidates(scope)
        scoped_issues(scope).keys
      end

      def build(issue)
        metadata = state_metadata_for(issue)

        {
          severity: :warning,
          title: "PR ##{issue.github_number} is wedged waiting on #{metadata[:requested_bot] || "review bot"}",
          description: "#{metadata[:consecutive_polls]} consecutive poll cycles emitted an unsatisfied pending review trigger.",
          nav_section: "projects",
          action_url: project_path(issue.project),
          metadata: {
            consecutive_polls: metadata[:consecutive_polls].to_i,
            requested_bot: metadata[:requested_bot],
            pr_phase: metadata[:pr_phase]
          }.compact
        }
      end

      def scoped_issues(scope)
        @scoped_issues ||= begin
          entries = Array(scope).filter_map do |entry|
            next unless entry.is_a?(Hash)

            entry.with_indifferent_access
          end
          issues = Issue.where(id: entries.map { |entry| entry[:issue_id] }).index_by { |issue| issue_key(issue.id) }
          entries.each_with_object({}) do |entry, result|
            issue = issues[issue_key(entry[:issue_id])]
            result[issue] = entry if issue
          end
        end
      end

      def issue_key(issue_id)
        issue_id.to_s
      end

      def update_state!(issue, entry)
        metadata = state_metadata_for(issue)
        reference_updated_at = issue.github_updated_at&.iso8601
        requested_bot = entry[:requested_bot]
        last_seen_at = parse_time(metadata[:last_seen_at])

        reset = metadata.blank? ||
          last_seen_at.blank? ||
          last_seen_at < WINDOW.ago ||
          metadata[:requested_bot] != requested_bot ||
          metadata[:reference_updated_at] != reference_updated_at

        consecutive_polls = reset ? 1 : metadata[:consecutive_polls].to_i + 1
        first_seen_at = reset ? Time.current : parse_time(metadata[:first_seen_at]) || Time.current

        save_state!(
          issue,
          first_seen_at: first_seen_at,
          last_seen_at: Time.current,
          metadata: {
            consecutive_polls: consecutive_polls,
            requested_bot: requested_bot,
            pr_phase: entry[:pr_phase],
            reference_updated_at: reference_updated_at,
            first_seen_at: first_seen_at.iso8601,
            last_seen_at: Time.current.iso8601
          }.compact
        )
      end
    end
  end
end
