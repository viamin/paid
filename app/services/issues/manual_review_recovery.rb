# frozen_string_literal: true

module Issues
  # Determines the recovery action from state owned by the producer of the
  # hold.  `manual_review_reason` remains display text; it is never used as a
  # routing protocol.
  # @spec OPERATOR-INBOX-002D ISSUE-REOPEN-REVIEW-005
  class ManualReviewRecovery
    Result = Data.define(:cause, :message, :blockers) do
      def enhancement? = cause == :enhancement
      def reopen_review? = cause == :reopen_review
      def dependency? = cause == :dependency
      def scanner? = cause == :scanner
      def unknown? = cause == :unknown
    end

    def self.call(issue:) = new(issue:).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return Result.new(:reopen_review, issue.manual_review_reason, []) if issue.reopen_review_pending?

      blockers = dependency_blockers
      return Result.new(:dependency, issue.manual_review_reason, blockers) if blockers.any?

      scanner_blockers = Issues::CloseoutStatus.scanner_verification_blockers(issue)
      return Result.new(:scanner, issue.manual_review_reason, scanner_blockers) if scanner_blockers.any?

      return Result.new(:enhancement, issue.manual_review_reason, []) if enhancement_provenance?

      Result.new(:unknown, issue.manual_review_reason.presence || "Manual review required.", [])
    end

    private

    attr_reader :issue

    def dependency_blockers
      issue.blocking_issues.to_a + issue.blocking_deployment_dependencies.map(&:depends_on_issue) + issue.blocking_external_dependencies.to_a
    end

    # Questions and a completed enhancement attempt are durable, local
    # provenance.  Do not infer an action from free-form failure copy.
    def enhancement_provenance?
      issue.needs_input_questions.present? ||
        issue.agent_runs.where(goal: "enhance_issue").exists? ||
        known_enhancement_stop_reason?
    end

    # These messages are fixed producer outputs from EnhanceIssueActivity and
    # QueueAgentRunActivity. They are provenance already persisted before this
    # classifier runs, unlike an operator's arbitrary manual-review note.
    def known_enhancement_stop_reason?
      issue.manual_review_reason.to_s.match?(
        /(?:configured (?:the )?limit(?: of \d+ enhancement re-evaluation rounds|)|Round limit reached)|structured output|Enhancement transport failed/i
      )
    end
  end
end
