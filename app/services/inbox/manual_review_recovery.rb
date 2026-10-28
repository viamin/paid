# frozen_string_literal: true

module Inbox
  # Classifies a manual-review hold from durable state, never from matching
  # words in an agent message.  The result is shared by the Inbox web/API
  # projections and the mutation endpoint so a button cannot promise a
  # recovery that the server will subsequently reinterpret.
  # @spec OPERATOR-INBOX-002L ISSUE-REOPEN-REVIEW-005
  class ManualReviewRecovery
    Cause = Data.define(:kind, :summary, :action, :dependencies) do
      def enhancement? = kind == :enhancement
      def reopen_review? = kind == :reopen_review
      def dependency? = kind == :dependency
      def scanner? = kind == :scanner
      def unknown? = kind == :unknown
    end

    def self.call(issue)
      new(issue).call
    end

    def initialize(issue)
      @issue = issue
    end

    def call
      return reopen_review if issue.reopen_review_pending?
      return dependency if dependencies.any?
      return scanner if scanner_blockers.any?
      return enhancement if enhancement_provenance?

      Cause.new(kind: :unknown, summary: issue.manual_review_reason.presence || "Manual review required.",
        action: :investigate, dependencies: [])
    end

    private

    attr_reader :issue

    def reopen_review
      Cause.new(kind: :reopen_review,
        summary: "This issue was reopened after closure. Validate the prior closure and current scope before resuming work.",
        action: :record_reopen_decision, dependencies: [])
    end

    def dependency
      refs = dependencies.map { |dependency| dependency.external? ? dependency.external_ref : "##{dependency.depends_on_issue.github_number}" }
      Cause.new(kind: :dependency, summary: "Work is waiting for unresolved dependency #{refs.join(', ')}.",
        action: :wait_for_dependency, dependencies: dependencies)
    end

    def scanner
      Cause.new(kind: :scanner, summary: scanner_blockers.map(&:message).join(" "), action: :review_scanner, dependencies: [])
    end

    def enhancement
      Cause.new(kind: :enhancement, summary: issue.manual_review_reason.presence || "Enhancement needs operator input.",
        action: :retry_enhancement, dependencies: [])
    end

    def dependencies
      @dependencies ||= issue.issue_dependencies.includes(:depends_on_issue).select do |dependency|
        dependency.external? || dependency.depends_on_issue&.github_state == "open"
      end
    end

    def scanner_blockers
      @scanner_blockers ||= Issues::CloseoutStatus.scanner_verification_blockers(issue)
    end

    def enhancement_provenance?
      issue.needs_input_questions.present? || issue.agent_runs.where(goal: "enhance_issue").exists?
    end
  end
end
