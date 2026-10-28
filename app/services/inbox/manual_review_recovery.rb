# frozen_string_literal: true

module Inbox
  # Determines the recovery that the source which parked an issue supports.
  # Reasons are display text and are deliberately not used as provenance.
  # @spec OPERATOR-INBOX-002L
  class ManualReviewRecovery
    Result = Data.define(:cause, :action, :blockers) do
      def reopen_review? = cause == :reopen_review
      def dependency? = cause == :dependency
      def actionable? = action != :none && action != :wait_for_dependency
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return Result.new(cause: :reopen_review, action: :record_reopen_decision, blockers: []) if issue.reopen_review_pending?
      return Result.new(cause: :dependency, action: :wait_for_dependency, blockers:) if blockers.any?
      return Result.new(cause: :scanner_recurrence, action: :resume_implementation, blockers: []) if scanner_recurrence?
      return Result.new(cause: :enhancement, action: :retry_enhancement, blockers: []) if enhancement_provenance?

      Result.new(cause: :unknown, action: :none, blockers: [])
    end

    private

    attr_reader :issue

    def blockers
      @blockers ||= issue.blocking_issues.to_a +
        issue.blocking_deployment_dependencies.map(&:depends_on_issue) +
        issue.blocking_external_dependencies.to_a
    end

    def enhancement_provenance?
      issue.needs_input_questions.present? || issue.agent_runs.where(goal: "enhance_issue").exists? ||
        issue.manual_review_reason.to_s.in?(ENHANCEMENT_STOP_REASONS) ||
        ENHANCEMENT_STOP_PREFIXES.any? { |prefix| issue.manual_review_reason.to_s.start_with?(prefix) }
    end

    ENHANCEMENT_STOP_REASONS = [
      "Paid could not validate the enhancement agent's structured output.",
      "Structured output was invalid.",
      "Round limit reached."
    ].freeze

    ENHANCEMENT_STOP_PREFIXES = [
      "Paid reached the configured limit of",
      "Paid could not validate the enhancement agent's"
    ].freeze

    def scanner_recurrence?
      issue.code_scanning_remediation_attempts.where(status: "verification_failed").exists?
    end
  end
end
