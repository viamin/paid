# frozen_string_literal: true

module Inbox
  # Classifies a manual-review hold from persisted producer evidence. Only
  # stable producer markers (including deterministic legacy stop reasons) may
  # select a recovery action; all other prose remains an unknown hold.
  # @spec OPERATOR-INBOX-002K
  class ManualReviewRecovery
    Result = Struct.new(:cause, :action, :references, keyword_init: true) do
      def retry_enhancement?
        action == :retry_enhancement
      end
    end

    DEPENDENCY_REASON_PREFIX = "Paid's agent run completed and opened a pull request, but this issue remains open and is blocked on an unresolved dependency:".freeze
    ENHANCEMENT_REASON_PREFIXES = [
      "Paid reached the configured limit of ",
      "Paid could not validate the enhancement agent's structured output.",
      "Structured output failed validation.",
      "Round limit reached."
    ].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(issue:)
      @issue = issue
    end

    def call
      return result(:reopen_review, :record_reopen_validation) if issue.reopen_review_pending?
      return result(:scanner_recurrence, :authorize_scanner_remediation) if scanner_recurrence?
      return result(:dependency_wait, :wait_for_dependency, dependency_references) if dependency_wait?
      return result(:enhancement, :retry_enhancement) if enhancement_hold?

      result(:unknown, :investigate)
    end

    private

    attr_reader :issue

    def result(cause, action, references = [])
      Result.new(cause:, action:, references:)
    end

    def scanner_recurrence?
      issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE &&
        issue.code_scanning_remediation_attempts.latest_per_issue.where(status: "verification_failed").exists?
    end

    def dependency_wait?
      issue.manual_review_reason.to_s.start_with?(DEPENDENCY_REASON_PREFIX) && dependency_references.any?
    end

    def dependency_references
      Issues::CloseoutStatus.prerequisite_labels(issue)
    end

    def enhancement_hold?
      issue.needs_input_questions.present? ||
        issue.agent_runs.where(goal: "enhance_issue").exists? ||
        ENHANCEMENT_REASON_PREFIXES.any? { |prefix| issue.manual_review_reason.to_s.start_with?(prefix) }
    end
  end
end
