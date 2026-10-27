# frozen_string_literal: true

module Inbox
  # Classifies only durable, machine-owned manual-review provenance.  The Inbox
  # must not guess a recovery path from arbitrary operator-authored prose.
  # @spec OPERATOR-INBOX-002L
  class ManualReviewRecovery
    Result = Data.define(:kind, :dependency) do
      def enhancement? = kind == :enhancement
      def reopen_review? = kind == :reopen_review
      def dependency? = kind == :dependency
      def scanner_recurrence? = kind == :scanner_recurrence
      def unknown? = kind == :unknown
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return Result.new(kind: :reopen_review, dependency: nil) if issue.reopen_review_pending?
      return Result.new(kind: :dependency, dependency:) if dependency
      return Result.new(kind: :scanner_recurrence, dependency: nil) if scanner_recurrence?
      return Result.new(kind: :enhancement, dependency: nil) if enhancement_stop?

      Result.new(kind: :unknown, dependency: nil)
    end

    private

    attr_reader :issue

    def dependency
      @dependency ||= issue.blocking_issues.order(:github_number).first
    end

    def scanner_recurrence?
      issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE &&
        issue.code_scanning_remediation_attempts.where(status: "verification_failed").exists?
    end

    def enhancement_stop?
      issue.needs_input_questions.present? ||
        issue.manual_review_reason == IssueEnhancements::StopForManualReview::UNPARSEABLE_OUTPUT_REASON ||
        issue.manual_review_reason == IssueEnhancements::StopForManualReview::LEGACY_UNPARSEABLE_OUTPUT_REASON ||
        issue.manual_review_reason == IssueEnhancements::StopForManualReview::ROUND_LIMIT_REASON
    end
  end
end
