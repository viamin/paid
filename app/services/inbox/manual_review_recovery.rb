# frozen_string_literal: true

module Inbox
  # Classifies a manual-review hold from durable records.  The reason text is
  # operator-facing evidence, never a control-plane input: it can be changed
  # by a producer and must not decide which recovery mutates work.
  # @spec ISSUE-REOPEN-REVIEW-005 @spec GITHUB-SYNC-017 @spec ISSUE-ENHANCEMENT-011
  class ManualReviewRecovery
    Recovery = Data.define(:cause, :action, :blockers, :active_run) do
      def enhancement? = cause == :enhancement
      def dependency? = cause == :dependency
      def reopen_review? = cause == :reopen_review
      def scanner_recurrence? = cause == :scanner_recurrence
      def unknown? = cause == :unknown
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return Recovery.new(cause: :reopen_review, action: :record_intent_validation, blockers: [], active_run:) if issue.reopen_review_pending?
      return Recovery.new(cause: :dependency, action: :wait_for_dependency, blockers:, active_run:) if blockers.any?
      return Recovery.new(cause: :scanner_recurrence, action: :review_scanner_evidence, blockers: [], active_run:) if scanner_recurrence?
      return Recovery.new(cause: :enhancement, action: :retry_enhancement, blockers: [], active_run:) if enhancement_provenance?

      Recovery.new(cause: :unknown, action: :inspect_provenance, blockers: [], active_run:)
    end

    private

    attr_reader :issue

    def active_run
      @active_run ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :desc, id: :desc).first
    end

    def blockers
      @blockers ||= issue.blocking_issues.to_a + issue.blocking_deployment_dependencies.to_a + issue.blocking_external_dependencies.to_a
    end

    def scanner_recurrence?
      issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE && issue.code_scanning_remediation_attempts.exists?
    end

    def enhancement_provenance?
      issue.needs_input_questions.present? || issue.agent_runs.where(goal: "enhance_issue").exists?
    end
  end
end
