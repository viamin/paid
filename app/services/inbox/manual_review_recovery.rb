# frozen_string_literal: true

module Inbox
  # Determines the recovery surface from durable records, never from the
  # operator-facing reason text. Manual review is a shared state, not a cause.
  # @spec OPERATOR-INBOX-002H
  class ManualReviewRecovery
    Result = Data.define(:cause, :action, :summary, :dependencies)

    def self.call(...) = new(...).call

    def initialize(issue)
      @issue = issue
    end

    def call
      return reopen_review if issue.reopen_review_pending?
      return dependency_wait if dependencies.any?
      return scanner_recurrence if scanner_recurrence?
      return enhancement if enhancement_stop?
      return technical_failure if technical_failure?

      unknown
    end

    private

    attr_reader :issue

    def reopen_review
      Result.new(
        cause: :reopen_review,
        action: :analyze_issue,
        summary: "Prior closure must be validated. " \
          "Reopen reason: #{issue.reopen_reason.presence || 'not recorded'}.",
        dependencies: []
      )
    end

    def dependency_wait
      Result.new(
        cause: :dependency,
        action: :wait_for_dependency,
        summary: "Work is waiting for unresolved dependency #{dependency_numbers}.",
        dependencies: dependencies
      )
    end

    def scanner_recurrence
      Result.new(
        cause: :scanner_recurrence,
        action: :create_pr,
        summary: "Scanner-confirmed recurrence requires a remediation implementation run.",
        dependencies: []
      )
    end

    def enhancement
      Result.new(
        cause: :enhancement,
        action: :enhance_issue,
        summary: issue.manual_review_reason.presence || "Enhancement requires operator review.",
        dependencies: []
      )
    end

    def technical_failure
      Result.new(
        cause: :technical_failure,
        action: :analyze_issue,
        summary: "A technical recovery is required; retry analysis using the recorded failure recovery policy.",
        dependencies: []
      )
    end

    def unknown
      Result.new(
        cause: :unknown,
        action: :none,
        summary: issue.manual_review_reason.presence || "Manual review required; recovery cause is unavailable.",
        dependencies: []
      )
    end

    def dependencies
      @dependencies ||= issue.blocking_issues.order(:github_number).to_a
    end

    def dependency_numbers
      dependencies.map { |dependency| "##{dependency.github_number}" }.join(", ")
    end

    def scanner_recurrence?
      issue.code_scanning_remediation_attempts.where(status: "verification_failed").exists?
    end

    def enhancement_stop?
      issue.agent_runs.where(goal: "enhance_issue").exists? || issue.needs_input_questions.present?
    end

    def technical_failure?
      latest_run = issue.agent_runs.order(created_at: :desc, id: :desc).first
      return false unless latest_run&.status.in?(AgentRun::FAILURE_STATUSES)

      FailureClassification.where(agent_run: latest_run).exists?
    end
  end
end
