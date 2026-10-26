# frozen_string_literal: true

module Inbox
  # Selects a recovery action from durable manual-review provenance. Reason
  # prose is deliberately display-only: it is not a safe control plane.
  # @spec OPERATOR-INBOX-002K
  class ManualReviewRecovery
    ENHANCEMENT_REASONS = [
      "Paid reached the configured enhancement-round limit.",
      "Paid reached the configured limit of enhancement re-evaluation rounds.",
      "Round limit reached."
    ].freeze
    Recovery = Data.define(:cause, :action, :dependencies, :run, :blockers) do
      def requires_decision? = cause == :reopen_review
      def actionable? = action != :none && action != :wait_for_dependency
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return recovery(:reopen_review, :enhance) if issue.reopen_review_pending?
      return recovery(:dependency, :wait_for_dependency, dependencies: dependencies) if dependencies.any?
      return recovery(:scanner_recurrence, :remediate, blockers: scanner_blockers) if scanner_blockers.any?
      return recovery(:questions, :enhance) if issue.needs_input_questions.present?
      return recovery(:enhancement_failure, :retry, run: latest_enhancement_run) if failed_enhancement_run?
      return recovery(:enhancement, :enhance) if latest_enhancement_run&.enhance_issue_goal?
      return recovery(:enhancement, :enhance) if ENHANCEMENT_REASONS.include?(issue.manual_review_reason)

      recovery(:unknown, :none)
    end

    private

    attr_reader :issue

    def recovery(cause, action, dependencies: [], run: nil, blockers: [])
      Recovery.new(cause:, action:, dependencies:, run:, blockers:)
    end

    def dependencies
      @dependencies ||= (issue.blocking_issues.to_a + issue.blocking_deployment_dependencies.to_a).uniq
    end

    def scanner_blockers
      @scanner_blockers ||= Issues::CloseoutStatus.scanner_verification_blockers(issue)
    end

    def latest_enhancement_run
      @latest_enhancement_run ||= issue.agent_runs.where(goal: "enhance_issue").order(created_at: :desc, id: :desc).first
    end

    def failed_enhancement_run?
      latest_enhancement_run&.finished? && latest_enhancement_run.status != "completed"
    end
  end
end
