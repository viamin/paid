# frozen_string_literal: true

module Inbox
  # Classifies a manual-review stop from persisted producer provenance. It
  # deliberately has no reason-text guessing: an unrecognized stop stays
  # visible as unknown rather than gaining the wrong recovery authority.
  # @spec OPERATOR-INBOX-002L
  class ManualReviewCause
    Cause = Data.define(:kind, :dependencies, :latest_run)

    def self.call(issue) = new(issue).call

    def initialize(issue)
      @issue = issue
    end

    def call
      return cause(:unknown) unless issue

      dependencies = unresolved_dependencies
      return cause(:dependency, dependencies:) if dependencies.any?
      return cause(:reopen_review) if issue.reopen_review_pending?
      return cause(:scanner_recurrence) if scanner?
      return cause(:enhancement) if enhancement?
      return cause(:technical_failure) if latest_run&.status.in?(AgentRun::FINISHED_STATUSES)

      cause(:unknown)
    end

    private

    attr_reader :issue

    def cause(kind, dependencies: [])
      Cause.new(kind:, dependencies:, latest_run: issue && latest_run)
    end

    def unresolved_dependencies
      issue.dependencies.where(github_state: "open")
        .where.not(paid_state: Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES).to_a
    end

    def scanner?
      issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE
    end

    def enhancement?
      issue.needs_input_questions.present? || latest_run&.enhance_issue_goal? ||
        IssueEnhancements::StopForManualReview.enhancement_reason?(issue.manual_review_reason)
    end

    def latest_run
      @latest_run ||= issue.agent_runs.order(created_at: :desc, id: :desc).first
    end
  end
end
