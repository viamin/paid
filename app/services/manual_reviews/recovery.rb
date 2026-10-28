# frozen_string_literal: true

module ManualReviews
  # Selects a recovery from durable state, never from operator-visible prose.
  # @spec OPERATOR-INBOX-002L
  class Recovery
    Result = Data.define(:cause, :action, :active_run, :dependencies, :scanner_attempt) do
      def active? = active_run.present?
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      result = classified_result
      return result unless active_run
      return result if compatible?(result)

      Result.new(cause: result.cause, action: :reconcile_active_run, active_run:, dependencies: result.dependencies, scanner_attempt: result.scanner_attempt)
    end

    private

    attr_reader :issue

    def classified_result
      return result(:reopen_review, :record_reopen_review) if issue.reopen_review_pending?
      return result(:dependency, :wait_for_dependency, dependencies: issue.blocking_issues.to_a) unless issue.ready_to_work?
      return scanner_result if scanner_attempt
      return result(:enhancement_questions, :answer_questions) if issue.needs_input_questions.present? && latest_run&.enhance_issue_goal?
      return result(:enhancement_failure, :retry_enhancement) if latest_run&.enhance_issue_goal?

      result(:unknown, :none)
    end

    def scanner_result
      action = scanner_attempt.status == "verification_failed" ? :resume_implementation : :wait_for_scanner
      cause = scanner_attempt.status == "verification_failed" ? :scanner_recurrence : :scanner_wait
      result(cause, action, scanner_attempt:)
    end

    def result(cause, action, dependencies: [], scanner_attempt: nil)
      Result.new(cause:, action:, active_run: nil, dependencies:, scanner_attempt:)
    end

    def scanner_attempt
      return unless issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE

      issue.code_scanning_remediation_attempts.latest_per_issue.first
    end

    def latest_run
      @latest_run ||= issue.agent_runs.order(created_at: :desc, id: :desc).first
    end

    def active_run
      @active_run ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :desc, id: :desc).first
    end

    def compatible?(result)
      result.action == :answer_questions ||
        (result.action == :retry_enhancement && active_run.enhance_issue_goal?)
    end
  end
end
