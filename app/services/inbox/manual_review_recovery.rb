# frozen_string_literal: true

module Inbox
  # Classifies a manual-review hold from its producer evidence. Copy is not a
  # control plane: callers use the returned action to select an existing,
  # authorized recovery path rather than inferring one from a reason string.
  # @spec ISSUE-REOPEN-REVIEW-005 ISSUE-REOPEN-REVIEW-006
  class ManualReviewRecovery
    Result = Data.define(:cause, :action, :dependencies, :active_runs) do
      def requires_decision? = action == :record_reopen_decision
      def waiting? = action == :wait_for_dependency
      def active? = active_runs.any?
    end

    ENHANCEMENT_REASON = /enhance|clarif|question|structured output|round/i

    def self.for(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return result(:unknown, :none) if issue.nil?

      return result(:reopen_review, :record_reopen_decision) if issue.reopen_review_pending?
      return result(:dependency, :wait_for_dependency, dependencies: dependencies) if dependencies.any?
      return result(:scanner_recurrence, :review_scanner_evidence) if scanner_recurrence?
      return result(:enhancement, :resume_enhancement) if enhancement_stop?

      result(:unknown, :none)
    end

    private

    attr_reader :issue

    def result(cause, action, dependencies: [])
      Result.new(cause, action, dependencies, active_runs)
    end

    def dependencies
      @dependencies ||= issue.blocking_issues.to_a + issue.blocking_deployment_dependencies.map(&:depends_on_issue) + issue.blocking_external_dependencies.to_a
    end

    def active_runs
      return [] if issue.nil?

      @active_runs ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :asc, id: :asc).to_a
    end

    def scanner_recurrence?
      issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE &&
        Issues::CloseoutStatus.scanner_verification_blockers(issue).any?
    end

    def enhancement_stop?
      issue.needs_input_questions.present? ||
        issue.manual_review_reason.to_s.match?(ENHANCEMENT_REASON) ||
        issue.agent_runs.order(created_at: :desc, id: :desc).first&.enhance_issue_goal?
    end
  end
end
