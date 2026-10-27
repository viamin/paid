# frozen_string_literal: true

module Inbox
  # Resolves the action an operator may take from durable manual-review
  # provenance. Reasons remain display text; they are not a policy API.
  # @spec OPERATOR-INBOX-002K ISSUE-REOPEN-REVIEW-005
  class ManualReviewRecovery
    Recovery = Data.define(:cause, :action, :blockers) do
      def actionable?
        action != :none && action != :wait
      end
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return Recovery.new(cause: :reopen_review, action: :record_decision, blockers: []) if issue.reopen_review_pending?
      return Recovery.new(cause: :dependency, action: :wait, blockers: dependency_blockers) if dependency_blockers.any?
      return Recovery.new(cause: :scanner_recurrence, action: :resume_implementation, blockers: []) if scanner_recurrence?
      return Recovery.new(cause: :enhancement, action: :retry_enhancement, blockers: []) if enhancement_provenance?

      Recovery.new(cause: :unknown, action: :none, blockers: [])
    end

    private

    attr_reader :issue

    def dependency_blockers
      @dependency_blockers ||= issue.issue_dependencies.includes(:depends_on_issue).filter_map do |dependency|
        dependency.depends_on_issue if dependency.depends_on_issue&.github_state == "open"
      end
    end

    def scanner_recurrence?
      issue.code_scanning_remediation_attempts.where(status: "verification_failed").exists?
    end

    def enhancement_provenance?
      issue.needs_input_questions.present? ||
        issue.manual_review_reason.to_s.match?(/enhancement|clarifying|structured output|round limit/i) ||
        issue.agent_runs.where(goal: "enhance_issue").exists?
    end
  end
end
