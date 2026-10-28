# frozen_string_literal: true

module Issues
  # Classifies a parked issue from durable state rather than the prose stored
  # in manual_review_reason.  The reason remains operator-visible evidence,
  # but must not decide which recovery is safe to run.
  class ManualReviewRecovery
    Recovery = Data.define(:kind, :message, :blocking_dependencies, :active_run)

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    # @spec ISSUE-REOPEN-REVIEW-005
    def call
      return Recovery.new(:reopen_review, "Validate the previous closure and current scope before resuming work.", [], active_run) if issue.reopen_review_pending?
      return Recovery.new(:active_work, "Run ##{active_run.id} is already #{active_run.status}; reconcile that work before starting another run.", [], active_run) if active_run
      return Recovery.new(:dependency, dependency_message, dependencies, nil) if dependencies.any?
      return Recovery.new(:scanner_recurrence, "A scanner-confirmed recurrence needs technical validation; retry analysis rather than enhancement.", [], nil) if scanner_recurrence?
      return Recovery.new(:enhancement, "Resume the enhancement review with a manual enhancement run.", [], nil) if enhancement_provenance?

      Recovery.new(:unknown, "The recorded manual-review cause is unknown. No automated recovery was started.", [], nil)
    end

    # @spec ISSUE-REOPEN-REVIEW-005
    def validate_reopen!(actor:, reason:)
      raise ArgumentError, "A reopen-review reason is required." if reason.to_s.strip.blank?

      issue.with_lock do
        issue.reload
        raise ArgumentError, "This issue is no longer waiting for reopen review." unless issue.reopen_review_pending?

        OrchestrationDecision.record!(
          project: issue.project,
          issue: issue,
          decision_point: "manual_review_reopen_validation",
          action: "validate_reopen_intent",
          status: "applied",
          context: { evidence_revision: (issue.github_updated_at || issue.updated_at).utc.iso8601, actor_id: actor.id },
          signals: { original_closure: issue.reopen_reason, remaining_scope_reason: reason.to_s.strip },
          result: { continuation: "automatic_re_evaluation" }
        )
        issue.update!(paid_state: "new")
      end
    end

    private

    attr_reader :issue

    def active_run
      @active_run ||= issue.project.agent_runs.where(issue: issue, status: AgentRun::UNFINISHED_STATUSES).order(created_at: :desc).first
    end

    def dependencies
      @dependencies ||= issue.blocking_issues.to_a + issue.blocking_deployment_dependencies.map(&:depends_on_issue) + issue.blocking_external_dependencies.to_a
    end

    def dependency_message
      refs = dependencies.map { |dependency| dependency.respond_to?(:external_ref) ? dependency.external_ref : "##{dependency.github_number}" }
      "Work remains blocked on #{refs.join(', ')}. Resolve that dependency before resuming this issue."
    end

    def scanner_recurrence?
      Issues::CloseoutStatus.scanner_verification_blockers(issue).any?
    end

    def enhancement_provenance?
      issue.needs_input_questions.present? || issue.project.agent_runs.where(issue: issue, goal: "enhance_issue").exists?
    end
  end
end
