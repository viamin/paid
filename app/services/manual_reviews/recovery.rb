# frozen_string_literal: true

# Classifies a manual-review hold from durable producer provenance.  It does
# not infer a cause from the wording of a human-readable reason: producers
# already leave structural evidence on the issue, its dependencies, runs, and
# scanner attempts.
# @spec OPERATOR-INBOX-002D ISSUE-REOPEN-REVIEW-005
module ManualReviews
  class Recovery
    Cause = Data.define(:kind, :action, :message, :blocking_records) do
      def enhancement? = action == :retry_enhancement
      def reopen_review? = action == :record_reopen_review
      def dependency? = action == :wait_for_dependency
    end

    REOPEN_REVIEW = :reopen_review
    DEPENDENCY = :dependency
    SCANNER_RECURRENCE = :scanner_recurrence
    ENHANCEMENT = :enhancement
    TECHNICAL_FAILURE = :technical_failure
    UNKNOWN = :unknown

    def self.for(issue) = new(issue:).cause

    def initialize(issue:)
      @issue = issue
    end

    def cause
      return reopen_review_cause if issue.reopen_review_pending?
      return dependency_cause if dependencies.any?
      return scanner_recurrence_cause if scanner_recurrence?
      return enhancement_cause if enhancement_hold?
      return technical_failure_cause if latest_failed_run

      Cause.new(kind: UNKNOWN, action: :investigate, message: issue.manual_review_reason.presence || "Manual review required.", blocking_records: [])
    end

    private

    attr_reader :issue

    def reopen_review_cause
      Cause.new(
        kind: REOPEN_REVIEW,
        action: :record_reopen_review,
        message: "Review the prior closure and remaining scope before continuing work.",
        blocking_records: []
      )
    end

    def dependency_cause
      Cause.new(
        kind: DEPENDENCY,
        action: :wait_for_dependency,
        message: "Work remains parked until its dependency is resolved; acknowledging this hold does not waive it.",
        blocking_records: dependencies
      )
    end

    def scanner_recurrence_cause
      Cause.new(
        kind: SCANNER_RECURRENCE,
        action: :review_scanner_evidence,
        message: "A scanner-confirmed recurrence needs evidence review and explicit remediation authorization.",
        blocking_records: Issues::CloseoutStatus.scanner_verification_blockers(issue)
      )
    end

    def enhancement_cause
      Cause.new(
        kind: ENHANCEMENT,
        action: :retry_enhancement,
        message: "Retry issue enhancement or answer the preserved clarifying questions.",
        blocking_records: []
      )
    end

    def technical_failure_cause
      Cause.new(
        kind: TECHNICAL_FAILURE,
        action: :inspect_failed_run,
        message: "Inspect the failed technical run before selecting its supported recovery action.",
        blocking_records: [ latest_failed_run ]
      )
    end

    def dependencies
      @dependencies ||= issue.blocking_issues.to_a +
        issue.blocking_deployment_dependencies.includes(:depends_on_issue).to_a +
        issue.blocking_external_dependencies.to_a
    end

    def scanner_recurrence?
      Issues::CloseoutStatus.scanner_verification_blockers(issue).any? do |blocker|
        blocker.code == :scanner_verification_failed
      end
    end

    def enhancement_hold?
      issue.needs_input_questions.present? || issue.agent_runs.where(goal: "enhance_issue").exists?
    end

    def latest_failed_run
      @latest_failed_run ||= issue.agent_runs.where(status: "failed").order(completed_at: :desc, id: :desc).first
    end
  end
end
