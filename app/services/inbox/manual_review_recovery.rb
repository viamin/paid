# frozen_string_literal: true

module Inbox
  # Chooses a manual-review action from durable state, rather than from the
  # human-readable stop message.  The message is evidence for an operator; it
  # is not a safe workflow discriminator.
  class ManualReviewRecovery
    Result = Data.define(:cause, :action, :message, :dependencies, :active_run)

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    # @spec OPERATOR-INBOX-002D, ISSUE-REOPEN-REVIEW-005
    def call
      return Result.new(cause: :reopen_review, action: :record_reopen_decision,
        message: "Validate the original closure and remaining scope before resuming work.", dependencies: [], active_run: active_run) if issue.reopen_review_pending?
      return dependency_result if dependencies.any?
      return Result.new(cause: :scanner_recurrence, action: :review_scanner_evidence,
        message: "Scanner evidence confirms the finding recurred; review the evidence before authorizing remediation.", dependencies: [], active_run: active_run) if scanner_recurrence?
      return Result.new(cause: :enhancement, action: :answer_questions,
        message: "Answer the preserved enhancement questions to retry analysis.", dependencies: [], active_run: active_run) if issue.needs_input_questions.present?
      return Result.new(cause: :enhancement, action: :retry_enhancement,
        message: "Retry the stopped enhancement analysis.", dependencies: [], active_run: active_run) if latest_run&.enhance_issue_goal?
      return Result.new(cause: :enhancement, action: :retry_enhancement,
        message: "Retry the stopped enhancement analysis.", dependencies: [], active_run: active_run) if enhancement_stop_reason?

      Result.new(cause: :unknown, action: :investigate,
        message: "Paid cannot determine why this manual-review hold was created. The hold remains in place until an operator investigates it.",
        dependencies: [], active_run: active_run)
    end

    private

    attr_reader :issue

    def dependencies
      @dependencies ||= issue.blocking_issues.to_a + issue.blocking_deployment_dependencies.to_a + issue.blocking_external_dependencies.to_a
    end

    def dependency_result
      Result.new(cause: :dependency, action: :wait_for_dependency,
        message: "Work is waiting for the listed dependency to resolve; acknowledging this hold does not waive it.",
        dependencies: dependencies, active_run: active_run)
    end

    def scanner_recurrence?
      Issues::CloseoutStatus.scanner_verification_blockers(issue).any? { |blocker| blocker.code == :scanner_verification_failed }
    end

    def latest_run
      @latest_run ||= issue.agent_runs.order(created_at: :desc, id: :desc).first
    end

    def active_run
      @active_run ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :desc, id: :desc).first
    end

    # These are the durable messages emitted by EnhanceIssueActivity and
    # StopForManualReview.  Older rows predate a structured provenance column,
    # so retain their known producer messages while keeping every other reason
    # visibly unknown instead of guessing from arbitrary text.
    def enhancement_stop_reason?
      issue.manual_review_reason.to_s.start_with?(
        "Paid reached the configured limit", "Round limit reached", "Structured output", "Paid could not validate the enhancement", "Enhancement transport failed"
      )
    end
  end
end
