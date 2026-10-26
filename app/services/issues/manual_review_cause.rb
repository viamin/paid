# frozen_string_literal: true

module Issues
  # Resolves a manual-review hold from durable state, never from the prose
  # intended for an operator.  The result is shared by every surface that
  # explains or recovers a hold so a UI cannot route differently from the API.
  # @spec OPERATOR-INBOX-002N
  class ManualReviewCause
    CAUSES = %w[reopen_review dependency_blocked scanner_verification enhancement unknown].freeze
    Result = Data.define(:name, :action, :active_run) do
      def enhancement?
        name == "enhancement"
      end

      def reopen_review?
        name == "reopen_review"
      end

      def dependency_blocked?
        name == "dependency_blocked"
      end

      def scanner_verification?
        name == "scanner_verification"
      end
    end

    def self.call(issue)
      new(issue).call
    end

    def initialize(issue)
      @issue = issue
    end

    def call
      Result.new(name: cause, action: action, active_run: active_run)
    end

    private

    attr_reader :issue

    def cause
      return "unknown" if issue.manual_review_cause.present? && !CAUSES.include?(issue.manual_review_cause)
      return explicit_cause if explicit_cause
      return "reopen_review" if issue.reopen_review_pending?
      return "dependency_blocked" if issue.blocking_issues.where(github_state: "open").exists?
      return "scanner_verification" if Issues::CloseoutStatus.scanner_verification_blockers(issue).any?
      return "enhancement" if enhancement_run?
      return "enhancement" if issue.manual_review_reason.present?

      "unknown"
    end

    def explicit_cause
      value = issue.manual_review_cause
      value if CAUSES.without("unknown").include?(value)
    end

    def action
      return "reconcile_active_run" if active_run
      return "record_reopen_decision" if cause == "reopen_review" && !issue.reopen_review_valid_for_current_evidence?
      return "wait_for_dependency" if cause == "dependency_blocked"
      return "review_scanner_recurrence" if cause == "scanner_verification"
      return "retry_enhancement" if cause == "enhancement"

      "investigate_unknown_hold"
    end

    def active_run
      @active_run ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :desc).first
    end

    def enhancement_run?
      active_run&.enhance_issue_goal? || issue.agent_runs.where(goal: "enhance_issue").exists?
    end
  end
end
