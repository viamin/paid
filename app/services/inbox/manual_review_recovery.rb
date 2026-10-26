# frozen_string_literal: true

module Inbox
  # Classifies a parked issue from durable state rather than from the prose in
  # +manual_review_reason+. Reasons are operator-facing diagnostics, not a
  # stable workflow protocol.
  class ManualReviewRecovery
    Recovery = Data.define(:cause, :action, :active_run, :dependency)
    ENHANCEMENT_STOP_REASONS = [
      "Structured output failed validation.",
      "Paid reached the configured limit of enhancement re-evaluation rounds."
    ].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(issue:)
      @issue = issue
    end

    # @spec OPERATOR-INBOX-002D, ISSUE-REOPEN-REVIEW-005
    def call
      return Recovery.new(cause: :active_work, action: :reconcile, active_run:, dependency: nil) if active_run
      return Recovery.new(cause: :reopen_review, action: :validate_intent, active_run: nil, dependency: nil) if issue.reopen_review_pending?
      return Recovery.new(cause: :dependency_wait, action: :wait_for_dependency, active_run: nil, dependency: blocking_dependency) if blocking_dependency
      return Recovery.new(cause: :scanner_recurrence, action: :resume_remediation, active_run: nil, dependency: nil) if scanner_recurrence?
      return Recovery.new(cause: :enhancement, action: :retry_enhancement, active_run: nil, dependency: nil) if enhancement_stop?

      Recovery.new(cause: :unknown, action: :investigate, active_run: nil, dependency: nil)
    end

    private

    attr_reader :issue

    def active_run
      @active_run ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :desc).first
    end

    def blocking_dependency
      @blocking_dependency ||= issue.blocking_issues.order(:github_number).first
    end

    def scanner_recurrence?
      issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE ||
        issue.code_scanning_remediation_attempts.where(status: "verification_failed").exists?
    end

    def enhancement_stop?
      issue.needs_input_questions.present? ||
        issue.agent_runs.where(goal: "enhance_issue").exists? ||
        ENHANCEMENT_STOP_REASONS.include?(issue.manual_review_reason)
    end
  end
end
