# frozen_string_literal: true

module Inbox
  # Classifies a manual-review hold from durable producer evidence. The reason
  # is presentation context, not an authority to select a recovery path.
  # @spec OPERATOR-INBOX-002L
  class ManualReviewRecovery
    Recovery = Data.define(:kind, :dependency) do
      def enhancement? = kind == :enhancement
      def reopen_review? = kind == :reopen_review
      def dependency? = kind == :dependency
      def scanner? = kind == :scanner
      def unknown? = kind == :unknown
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return Recovery.new(kind: :reopen_review, dependency: nil) if issue.reopen_review_pending?
      return Recovery.new(kind: :dependency, dependency: blocking_dependency) if blocking_dependency
      return Recovery.new(kind: :scanner, dependency: nil) if scanner_recurrence?
      return Recovery.new(kind: :enhancement, dependency: nil) if enhancement_hold?

      Recovery.new(kind: :unknown, dependency: nil)
    end

    private

    attr_reader :issue

    def blocking_dependency
      issue.blocking_issues.first || issue.blocking_deployment_dependencies.first || issue.blocking_external_dependencies.first
    end

    def scanner_recurrence?
      issue.code_scanning_remediation_attempts.latest_per_issue
        .where(status: %w[verification_failed verification_blocked]).exists?
    end

    def enhancement_hold?
      issue.needs_input_questions.present? ||
        issue.agent_runs.where(goal: "enhance_issue").order(created_at: :desc, id: :desc).first.present? ||
        legacy_enhancement_stop?
    end

    # Old stops predate a machine-readable producer field. These are the
    # exact stable messages emitted by the enhancement stop paths, retained as
    # compatibility provenance rather than treating arbitrary prose as intent.
    def legacy_enhancement_stop?
      issue.manual_review_reason.to_s.in?([
        "Paid could not validate the enhancement agent's structured output.",
        "Paid reached the configured limit of enhancement re-evaluation rounds.",
        "Round limit reached.",
        "Structured output failed validation."
      ])
    end
  end
end
