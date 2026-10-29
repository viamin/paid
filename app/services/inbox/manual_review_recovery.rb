# frozen_string_literal: true

module Inbox
  # Classifies a manual-review hold from durable producer evidence. The reason
  # is presentation context, not an authority to select a recovery path.
  # @spec OPERATOR-INBOX-002L
  class ManualReviewRecovery
    ENHANCEMENT_STOP_REASONS = [
      "Paid could not validate the enhancement agent's structured output.",
      "Paid reached the configured enhancement-round limit.",
      "Paid reached the configured limit of enhancement re-evaluation rounds.",
      "Round limit reached.",
      "Structured output failed validation."
    ].freeze
    ENHANCEMENT_ROUND_LIMIT_REASON = /\APaid (?:has )?reached the configured limit of \d+ enhancement re-evaluation rounds for this issue\.\z/

    Recovery = Data.define(:kind, :dependency, :scanner_attempt) do
      def enhancement? = kind == :enhancement
      def reopen_review? = kind == :reopen_review
      def dependency? = kind == :dependency
      def scanner? = kind == :scanner
      def unknown? = kind == :unknown

      # Only a scanner-confirmed recurrence (`verification_failed`) is an
      # operator decision to authorize new remediation; `verification_blocked`
      # stays with the automatic verifier (EAGER-QUEUE-013), which revisits it
      # on the next scan without a competing manually-triggered fix PR.
      def authorize_new_remediation? = scanner? && scanner_attempt&.status == "verification_failed"
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return Recovery.new(kind: :reopen_review, dependency: nil, scanner_attempt: nil) if issue.reopen_review_pending?
      return Recovery.new(kind: :dependency, dependency: blocking_dependency, scanner_attempt: nil) if blocking_dependency
      return Recovery.new(kind: :scanner, dependency: nil, scanner_attempt: scanner_attempt) if scanner_recurrence?
      return Recovery.new(kind: :enhancement, dependency: nil, scanner_attempt: nil) if enhancement_hold?

      Recovery.new(kind: :unknown, dependency: nil, scanner_attempt: nil)
    end

    private

    attr_reader :issue

    def blocking_dependency
      issue.blocking_issues.first || deployment_dependency_issue || issue.blocking_external_dependencies.first
    end

    def deployment_dependency_issue
      issue.blocking_deployment_dependencies.first&.depends_on_issue
    end

    def scanner_recurrence?
      scanner_attempt&.status.in?(%w[verification_failed verification_blocked])
    end

    def scanner_attempt
      @scanner_attempt ||= issue.code_scanning_remediation_attempts.latest_per_issue.first
    end

    def enhancement_hold?
      question_driven_hold? ||
        legacy_enhancement_stop?
    end

    # Questions are stored on the issue and outlive a manual-review episode.
    # They identify the current producer only when that producer supplied no
    # reason; a nonblank reason must match the durable legacy enhancement set.
    def question_driven_hold?
      issue.manual_review_reason.blank? && issue.needs_input_questions.present?
    end

    # Old stops predate a machine-readable producer field. These are the stable
    # messages and bounded dynamic template emitted by the enhancement stop
    # paths, retained as compatibility provenance rather than treating arbitrary
    # prose as intent.
    def legacy_enhancement_stop?
      reason = issue.manual_review_reason.to_s
      reason.in?(ENHANCEMENT_STOP_REASONS) || reason.match?(ENHANCEMENT_ROUND_LIMIT_REASON)
    end
  end
end
