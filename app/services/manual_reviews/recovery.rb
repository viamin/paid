# frozen_string_literal: true

# Determines a manual-review recovery from durable, local provenance.  The
# free-form reason remains operator-visible, but it is never parsed to decide
# what work to start.
module ManualReviews
  class Recovery
    ENHANCEMENT_REASON_PREFIXES = [
      "Paid reached the configured limit of enhancement re-evaluation rounds.",
      "Paid has reached the configured limit of",
      "Paid could not validate the enhancement agent's structured output.",
      "Structured output was invalid.",
      "Structured output failed validation.",
      "Round limit reached.",
      "Enhancement transport failed."
    ].freeze
    Result = Data.define(:cause, :action, :message, :blockers) do
      def reopen? = cause == :reopen
      def dependency? = cause == :dependency
      def enhancement? = cause == :enhancement
      def scanner? = cause == :scanner
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    # @spec OPERATOR-INBOX-002D ISSUE-REOPEN-REVIEW-005
    def call
      return reopen_review if issue.reopen_review_pending?
      return unresolved_dependency if dependency_blockers.any?
      return scanner_recurrence if scanner_blockers.any?
      return enhancement if enhancement_provenance?

      Result.new(cause: :unknown, action: :investigate,
        message: "Paid retained the recorded stop reason, but cannot safely infer a recovery action.", blockers: [])
    end

    private

    attr_reader :issue

    def reopen_review
      Result.new(cause: :reopen, action: :validate_intent,
        message: "Validate the original closure and remaining scope before continuing work.", blockers: [])
    end

    def unresolved_dependency
      Result.new(cause: :dependency, action: :wait_for_dependency,
        message: "Work remains blocked by an unresolved dependency. Resolve the linked work, then re-evaluate this item.",
        blockers: dependency_blockers)
    end

    def scanner_recurrence
      Result.new(cause: :scanner, action: :review_scanner_evidence,
        message: "Review the scanner evidence and authorize remediation through the existing closeout recovery controls.",
        blockers: scanner_blockers)
    end

    def enhancement
      Result.new(cause: :enhancement, action: :retry_enhancement,
        message: "Retry enhancement analysis after reviewing the recorded stop reason.", blockers: [])
    end

    def enhancement_provenance?
      issue.needs_input_questions.present? || issue.agent_runs.where(goal: "enhance_issue").exists? ||
        ENHANCEMENT_REASON_PREFIXES.any? { |prefix| issue.manual_review_reason.to_s.start_with?(prefix) }
    end

    def dependency_blockers
      @dependency_blockers ||= issue.blocking_issues.where(github_state: "open").to_a +
        issue.blocking_deployment_dependencies.includes(:depends_on_issue).filter_map do |dependency|
          dependency.depends_on_issue if dependency.depends_on_issue.github_state == "open"
        end
    end

    def scanner_blockers
      @scanner_blockers ||= Issues::CloseoutStatus.scanner_verification_blockers(issue)
    end
  end
end
