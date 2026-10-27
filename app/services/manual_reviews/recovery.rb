# frozen_string_literal: true

module ManualReviews
  # Determines the deterministic recovery contract for an Inbox hold.  This
  # deliberately uses persisted relationships and state, not prose in the
  # stop message: that prose is operator context, not an authorization signal.
  class Recovery
    Result = Data.define(:cause, :action, :message, :blocking_issues)

    def self.call(...)
      new(...).call
    end

    def initialize(issue:)
      @issue = issue
    end

    # @spec ISSUE-REOPEN-REVIEW-005 @spec OPERATOR-INBOX-002J
    def call
      return result(:reopen_review, :record_reopen_review, "Validate the original closure and current scope before continuing.") if issue.reopen_review_pending?
      return result(:scanner_recurrence, :review_scanner_evidence, "Scanner evidence requires remediation review before new work.") if scanner_recurrence?
      return result(:dependency_wait, :wait_for_dependency, "Waiting for the linked prerequisite work to resolve.", unresolved_dependencies) if unresolved_dependencies.any?
      return result(:enhancement, :retry_enhancement, "Resume the stopped enhancement work.") if legacy_enhancement_stop?

      result(:unknown, :investigate, "The recorded hold has no recognized recovery provenance.")
    end

    private

    attr_reader :issue

    def result(cause, action, message, blocking_issues = [])
      Result.new(cause, action, message, blocking_issues)
    end

    def scanner_recurrence?
      issue.code_scanning_remediation_attempts.where(status: "verification_failed").exists?
    end

    def unresolved_dependencies
      @unresolved_dependencies ||= issue.dependencies.where.not(github_state: "closed").order(:github_number).to_a
    end

    # Manual-review state predates recorded cause provenance. Preserve the
    # established enhancement recovery for those rows, while a blank reason is
    # intentionally surfaced as unknown rather than guessed.
    def legacy_enhancement_stop?
      issue.manual_review_reason.present?
    end
  end
end
