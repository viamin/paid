# frozen_string_literal: true

# Determines a manual-review recovery path from durable provenance, never from
# free-form operator copy.  A new producer must add an explicit branch here;
# unknown provenance deliberately remains visible and cannot be cleared by a
# generic retry.
# @spec OPERATOR-INBOX-002D ISSUE-REOPEN-REVIEW-005
module ManualReviews
  class Cause
    Result = Data.define(:kind, :blocking_issues, :external_dependencies, :scanner_attempt)

    REOPEN = :reopen_review
    DEPENDENCY = :dependency
    SCANNER = :scanner_recurrence
    ENHANCEMENT = :enhancement
    UNKNOWN = :unknown

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return Result.new(kind: REOPEN, blocking_issues: [], external_dependencies: [], scanner_attempt: nil) if issue.reopen_review_pending?
      return dependency_result if dependency_blocked?
      return scanner_result if scanner_attempt
      return Result.new(kind: ENHANCEMENT, blocking_issues: [], external_dependencies: [], scanner_attempt: nil) if enhancement_stop?

      Result.new(kind: UNKNOWN, blocking_issues: [], external_dependencies: [], scanner_attempt: nil)
    end

    private

    attr_reader :issue

    def dependency_blocked?
      issue.blocking_issues.exists? || issue.blocking_deployment_dependencies.exists? || issue.blocking_external_dependencies.exists?
    end

    def dependency_result
      Result.new(
        kind: DEPENDENCY,
        blocking_issues: issue.blocking_issues.to_a,
        external_dependencies: issue.blocking_external_dependencies.to_a,
        scanner_attempt: nil
      )
    end

    def scanner_attempt
      @scanner_attempt ||= issue.code_scanning_remediation_attempts
        .where(status: "verification_failed").order(created_at: :desc).first
    end

    def scanner_result
      Result.new(kind: SCANNER, blocking_issues: [], external_dependencies: [], scanner_attempt: scanner_attempt)
    end

    # Questions and an enhancement run are durable evidence that this is the
    # existing enhancement recovery path. Legacy enhancement stops retained
    # only their non-blank stop reason, so that established contract remains
    # backward compatible while an unannotated hold stays visibly unknown.
    def enhancement_stop?
      # Historical enhancement stops predate per-stop provenance. Their durable
      # non-blank stop reason is the legacy enhancement contract; an entirely
      # unannotated hold is deliberately left unknown.
      issue.needs_input_questions.present? || issue.agent_runs.where(goal: "enhance_issue").exists? || issue.manual_review_reason.present?
    end
  end
end
