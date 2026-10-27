# frozen_string_literal: true

module Issues
  # Classifies a stopped issue from durable producer evidence.  The Inbox must
  # not infer a recovery from the prose in manual_review_reason: that text is
  # operator-facing context, while the state that produced the hold is the
  # authority for what may clear it.
  # @spec ISSUE-REOPEN-REVIEW-005 @spec OPERATOR-INBOX-002L
  class ManualReviewRecovery
    Recovery = Data.define(:cause, :action, :message, :dependencies, :active_run) do
      def actionable?
        action.present?
      end
    end

    def self.for(issue)
      new(issue).for
    end

    def initialize(issue)
      @issue = issue
    end

    def for
      return active_work_recovery if active_run
      return reopen_recovery if issue.reopen_review_pending?
      return dependency_recovery if dependencies.any?
      return scanner_recovery if scanner_recurrence?
      return enhancement_recovery if enhancement_provenance?

      Recovery.new(cause: :unknown, action: nil,
        message: "Paid retained this manual-review hold, but its originating recovery action is unknown. Inspect the issue history before changing its state.",
        dependencies: [], active_run: nil)
    end

    private

    attr_reader :issue

    def active_run
      @active_run ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :desc).first
    end

    def dependencies
      @dependencies ||= issue.blocking_issues.includes(:project).to_a + issue.blocking_deployment_dependencies.includes(:depends_on_issue).map(&:depends_on_issue)
    end

    def active_work_recovery
      Recovery.new(cause: :active_work, action: nil,
        message: "Run ##{active_run.id} is already #{active_run.status}; reconcile that work before starting another recovery.",
        dependencies: [], active_run: active_run)
    end

    def reopen_recovery
      Recovery.new(cause: :reopen_review, action: :validate_reopen,
        message: "Review the prior closure and remaining scope, then record an intent-validation decision for revision #{issue.github_updated_at&.utc&.iso8601 || "unknown"}.",
        dependencies: [], active_run: nil)
    end

    def dependency_recovery
      Recovery.new(cause: :dependency, action: nil,
        message: "Work remains blocked by an unresolved dependency. Paid will reevaluate admission when it resolves.",
        dependencies: dependencies, active_run: nil)
    end

    def scanner_recovery
      Recovery.new(cause: :scanner_recurrence, action: :start_implementation,
        message: "Scanner evidence confirmed the finding recurred. Starting work resumes remediation; it does not treat the prior scan as resolved.",
        dependencies: [], active_run: nil)
    end

    def enhancement_recovery
      Recovery.new(cause: :enhancement, action: :retry_enhancement,
        message: "This hold came from issue enhancement. Retrying analysis preserves the existing enhancement recovery path.",
        dependencies: [], active_run: nil)
    end

    def scanner_recurrence?
      Issues::CloseoutStatus.scanner_verification_blockers(issue).any? { |blocker| blocker.code == :scanner_verification_failed }
    end

    def enhancement_provenance?
      issue.needs_input_questions.present? || issue.agent_runs.where(goal: "enhance_issue").exists?
    end
  end
end
