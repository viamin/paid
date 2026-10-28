# frozen_string_literal: true

module Inbox
  # Classifies a manual-review hold from durable producer evidence. Free-form
  # reason text remains presentation only; it never grants an action.
  # @spec OPERATOR-INBOX-002I @spec ISSUE-REOPEN-REVIEW-005
  class ManualReviewCause
    ENHANCEMENT_REASON_PREFIXES = [
      "Paid reached the configured enhancement-round limit",
      "Paid reached the configured limit of enhancement re-evaluation rounds",
      "Paid has reached the configured limit of",
      "Paid could not validate the enhancement agent's structured output",
      "Enhancement rounds exhausted",
      "Round limit reached",
      "Structured enhancement output was invalid",
      "Structured output failed validation",
      "Enhancement transport failed"
    ].freeze
    Cause = Data.define(:kind, :active_runs, :dependencies) do
      def enhancement? = kind == :enhancement
      def reopen_review? = kind == :reopen_review
      def dependency? = kind == :dependency
      def scanner? = kind == :scanner
      def technical? = kind == :technical
      def unknown? = kind == :unknown
    end

    def self.call(issue) = new(issue).call

    def initialize(issue)
      @issue = issue
    end

    def call
      Cause.new(kind:, active_runs:, dependencies:)
    end

    private

    attr_reader :issue

    def kind
      return :reopen_review if issue.reopen_review_pending?
      return :dependency if dependency_blocked?
      return :scanner if scanner_recurrence?
      return :technical if technical_recovery?
      return :enhancement if enhancement_provenance?

      :unknown
    end

    def dependencies
      @dependencies ||= issue.blocking_issues.to_a
    end

    def dependency_blocked?
      dependencies.any? || issue.blocking_external_dependencies.exists? ||
        issue.blocking_deployment_dependencies.exists?
    end

    def scanner_recurrence?
      Issues::CloseoutStatus.scanner_verification_blockers(issue).any?
    end

    def technical_recovery?
      issue.partial_completion_at.present? || latest_run&.technical_prerequisite_validation_goal?
    end

    def enhancement_provenance?
      issue.needs_input_questions.present? || latest_run&.goal == "enhance_issue" ||
        ENHANCEMENT_REASON_PREFIXES.any? { |prefix| issue.manual_review_reason.to_s.start_with?(prefix) }
    end

    def latest_run
      @latest_run ||= issue.agent_runs.order(created_at: :desc).first
    end

    def active_runs
      @active_runs ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(:id).to_a
    end
  end
end
