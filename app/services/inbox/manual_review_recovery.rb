# frozen_string_literal: true

module Inbox
  # Classifies a manual-review item from durable producer state.  Presentation
  # and mutation callers share this object so neither has to infer a recovery
  # from the human-readable stop message.
  # @spec OPERATOR-INBOX-002D
  class ManualReviewRecovery
    ENHANCEMENT_REASON_PREFIXES = [
      "Paid reached the configured limit of enhancement",
      "Paid has reached the configured limit of",
      "Structured output failed validation."
    ].freeze
    Result = Data.define(:cause, :message, :action, :blockers) do
      def reopen_review? = cause == :reopen_review
      def dependency? = cause == :dependency
      def scanner_recurrence? = cause == :scanner_recurrence
      def enhancement? = cause == :enhancement
      def unknown? = cause == :unknown
    end

    def self.call(...) = new(...).call

    def initialize(issue:, questions: [])
      @issue = issue
      @questions = questions
    end

    def call
      return reopen_review if issue.reopen_review_pending?
      return dependency if blockers.any?
      return scanner_recurrence if scanner_blockers.any?
      return enhancement if enhancement_provenance?

      unknown
    end

    private

    attr_reader :issue, :questions

    def reopen_review
      Result.new(:reopen_review,
        "This issue was reopened after Paid closed it. Review the prior closure and remaining scope before choosing evidence collection or implementation.",
        :record_reopen_decision, [])
    end

    def dependency
      numbers = blockers.map { |blocker| "##{blocker.github_number}" }.join(", ")
      Result.new(:dependency, "Work is waiting on #{numbers}. It will be reevaluated when that dependency resolves.", :wait_for_dependency, blockers)
    end

    def scanner_recurrence
      Result.new(:scanner_recurrence,
        "Scanner verification found the alert again. Review the evidence and explicitly start remediation only if new implementation is authorized.",
        :start_remediation, scanner_blockers)
    end

    def enhancement
      Result.new(:enhancement, "Enhancement work stopped and can be retried after answering any preserved questions.", :retry_enhancement, [])
    end

    def unknown
      Result.new(:unknown,
        "Paid retained this manual-review hold but has no recognized producer provenance. The hold remains visible; inspect the issue before selecting a supported run.",
        :inspect, [])
    end

    def blockers
      @blockers ||= issue.blocking_issues.to_a + issue.blocking_deployment_dependencies.to_a
    end

    def scanner_blockers
      @scanner_blockers ||= Issues::CloseoutStatus.scanner_verification_blockers(issue)
    end

    def enhancement_provenance?
      questions.any? ||
        issue.agent_runs.order(created_at: :desc, id: :desc).limit(1).pick(:goal) == "enhance_issue" ||
        ENHANCEMENT_REASON_PREFIXES.any? { |prefix| issue.manual_review_reason.to_s.start_with?(prefix) }
    end
  end
end
