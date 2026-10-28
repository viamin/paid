# frozen_string_literal: true

module Inbox
  # Makes the manual-review recovery route explicit. `manual_review` is a
  # presentation state, not a cause: the producer evidence decides whether an
  # operator must record intent, wait for a dependency, retry enhancement, or
  # resume remediation.
  class ManualReviewRecovery
    Result = Struct.new(:cause, :action, :continuation_goal, :active_run, :code, :message, keyword_init: true) do
      def success? = code.nil?
    end

    def self.call(...) = new(...).call

    def self.resolve(...) = new(...).resolve

    def initialize(issue:, actor: nil, revision: nil, decision: nil, reason: nil)
      @issue = issue
      @actor = actor
      @revision = revision
      @decision = decision
      @reason = reason.to_s.strip
    end

    # @spec OPERATOR-INBOX-002L
    def call
      return active_run_result if active_run
      return dependency_result if unresolved_dependency?
      return Result.new(cause: :reopen_review, action: :record_decision) if issue.reopen_review_pending?
      return Result.new(cause: :scanner_recurrence, action: :resume_remediation, continuation_goal: "create_pr") if scanner_recurrence?
      return Result.new(cause: :enhancement, action: :retry_enhancement, continuation_goal: "enhance_issue") if enhancement_hold?

      Result.new(cause: :unknown, action: :investigate)
    end

    # The decision is deliberately separate from queueing a continuation: a
    # client can use this same authorized operation to record the human review,
    # and only the controller that can start runs chooses the next run type.
    # @spec ISSUE-REOPEN-REVIEW-005 OPERATOR-INBOX-002L
    def resolve
      return Result.new(code: :invalid_decision, message: "Choose a supported continuation.") unless valid_decision?
      return Result.new(code: :reason_required, message: "Explain the reopen-review decision.") if reason.blank?

      issue.with_lock do
        issue.reload
        return Result.new(code: :not_pending, message: "This issue is no longer waiting for reopen review.") unless issue.reopen_review_pending?
        return Result.new(code: :stale_revision, message: "The issue changed on GitHub. Refresh it before deciding.") unless current_revision?
        return dependency_result if unresolved_dependency?
        return active_run_result if active_run
        return Result.new(cause: :reopen_review, action: :record_decision, code: :already_decided,
          message: "This reopen review was already decided for the current issue revision.") if prior_decision?

        Audit::RecordEvent.call(
          action: "issue.reopen_review_decided",
          actor:,
          subject: issue,
          metadata: { revision:, decision:, reason: }
        )
      end

      Result.new(cause: :reopen_review, action: :continue_implementation, continuation_goal: "create_pr")
    end

    private

    attr_reader :actor, :decision, :issue, :reason, :revision

    def active_run
      @active_run ||= issue.project.agent_runs
        .where(issue:, status: AgentRun::UNFINISHED_STATUSES)
        .order(created_at: :desc, id: :desc).first
    end

    def active_run_result
      Result.new(cause: cause_without_active_run, action: :reconcile_active_run, active_run:)
    end

    def cause_without_active_run
      return :dependency if unresolved_dependency?
      return :reopen_review if issue.reopen_review_pending?
      return :scanner_recurrence if scanner_recurrence?
      return :enhancement if enhancement_hold?

      :unknown
    end

    def dependency_result
      Result.new(cause: :dependency, action: :wait_for_dependency,
        code: :dependency_unresolved, message: "A required dependency is still unresolved.")
    end

    def unresolved_dependency?
      issue.blocking_issues.exists? || issue.blocking_deployment_dependencies.exists? || issue.blocking_external_dependencies.exists?
    end

    def scanner_recurrence?
      issue.code_scanning_remediation_attempts.where(status: "verification_failed").exists?
    end

    def enhancement_hold?
      issue.needs_input_questions.present? ||
        IssueEnhancements::StopForManualReview::ENHANCEMENT_REASONS.include?(issue.manual_review_reason) ||
        issue.agent_runs.where(goal: "enhance_issue", status: "failed").exists?
    end

    def valid_decision?
      decision == "resume_implementation"
    end

    def current_revision?
      revision.present? && revision == issue.github_updated_at.iso8601
    end

    def prior_decision?
      AccountActivityEvent.where(action: "issue.reopen_review_decided", subject: issue)
        .where("metadata ->> 'revision' = ?", revision).exists?
    end
  end
end
