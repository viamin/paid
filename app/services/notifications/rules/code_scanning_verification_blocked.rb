# frozen_string_literal: true

module Notifications
  module Rules
    # Surfaces unresolved code-scanning findings whose latest verification
    # attempt is `verification_blocked` so operators see retryable blockers
    # even when the issue is not in the manual_review lane yet. Auto-resolves
    # when the attempt transitions to `verified_fixed` or `verification_failed`
    # (the latter moves the issue into manual_review, providing the operator
    # escalation path; the manual_review lane replaces this notification).
    # @spec EAGER-QUEUE-016
    class CodeScanningVerificationBlocked < Rule
      SOURCE = "code_scanning_verification_blocked"

      def source = SOURCE

      def detect(scope)
        attempts = Array(scope)
        latest_blocked_ids = CodeScanningRemediationAttempt.latest_per_issue
          .where(id: attempts.map(&:id), status: "verification_blocked")
          .joins(:issue)
          .where(issues: { github_state: "open" })
          .pluck(:id)

        attempts.select { |attempt| latest_blocked_ids.include?(attempt.id) }
      end

      def resolve_candidates(scope)
        Array(scope)
      end

      def build(attempt)
        issue = attempt.issue
        project = issue.project

        {
          severity: :error,
          blocking: true,
          title: "Code scanning fix awaits scanner evidence",
          description: build_description(attempt),
          nav_section: "projects",
          action_url: project_path(project),
          metadata: build_metadata(attempt, project)
        }
      end

      private

      # The base Rule#account_for dispatches on subject.respond_to?(:account),
      # (:project), or (:user). A CodeScanningRemediationAttempt is an
      # indirect child of the issue/project, so fall through to the issue's
      # account here (#4152).
      def account_for(attempt)
        attempt.issue.project.account
      end

      def build_description(attempt)
        [
          "Alert #{alert_label(attempt)}: #{attempt.blocked_reason.to_s.presence || 'pending scanner evidence'}.",
          "Linked PR ##{attempt.pull_request_number} (#{short_sha(attempt.merge_commit_sha)}).",
          next_action_for(attempt)
        ].join(" ")
      end

      def build_metadata(attempt, project)
        issue = attempt.issue
        {
          alert_url: issue.github_url,
          issue_id: issue.id,
          issue_number: issue.github_number,
          project_id: project.id,
          attempt_id: attempt.id,
          pull_request_number: attempt.pull_request_number,
          merge_commit_sha: attempt.merge_commit_sha,
          blocked_reason: attempt.blocked_reason,
          blocked_at: attempt.updated_at&.iso8601,
          last_successful_scan_at: project.last_code_scanning_scan_at&.iso8601,
          tool_name: attempt.tool_name,
          category: attempt.category,
          verification_analysis_id: attempt.verification_analysis_id,
          recommended_action: next_action_for(attempt),
          remediation_steps: remediation_steps_for(attempt)
        }.compact
      end

      def next_action_for(attempt)
        if attempt.evidence["analysis_id"].present?
          "Awaiting the next code-scanning scan on #{attempt.issue.project.default_branch}; the verifier re-evaluates blocked attempts on every relevant scan."
        else
          "Wait for the next code-scanning scan or repair the GitHub App permission; verification will re-run automatically."
        end
      end

      def remediation_steps_for(attempt)
        steps = []
        steps << "Open the alert URL and confirm the CodeQL finding is still reported on the target branch."
        steps << "If the finding is closed, the next verification pass will mark this attempt verified_fixed."
        if attempt.blocked_reason.to_s.include?("configuration")
          steps << "If the scanner's tool/category changed, update the project's code-scanning configuration and re-scan."
        end
        steps << "If the finding is real, merge a fix; the new PR records a fresh attempt that supersedes this blocked row."
        steps
      end

      def alert_label(attempt)
        attempt.issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE ?
          "##{attempt.issue.github_issue_id - Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET}" :
          "##{attempt.issue.github_number}"
      end

      def short_sha(sha)
        return nil if sha.blank?

        sha[0, 7]
      end
    end
  end
end
