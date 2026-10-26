# frozen_string_literal: true

module Issues
  # Classifies a parked issue from durable records rather than from the prose
  # in `manual_review_reason`. The Inbox and endpoint share this projection.
  class ManualReviewRecovery
    Result = Data.define(:cause, :active_run, :dependencies, :scanner_blockers) do
      def blocked_by_active_run? = active_run.present?
      def blocked_by_dependency? = dependencies.any?
      def continuation_goal = { reopen: "create_pr", scanner: "create_pr", enhancement: "enhance_issue" }[cause]
      def continuation? = continuation_goal.present? && !blocked_by_active_run? && !blocked_by_dependency?
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    # @spec OPERATOR-INBOX-002L @spec ISSUE-REOPEN-REVIEW-005
    def call
      Result.new(cause:, active_run:, dependencies:, scanner_blockers:)
    end

    private

    attr_reader :issue

    def cause
      return :reopen if issue.reopen_review_pending?
      return :dependency if dependencies.any?
      return :scanner if scanner_blockers.any?
      return :unknown if issue.partial_completion_at?
      return :enhancement if enhancement_failure?

      :unknown
    end

    def active_run
      @active_run ||= issue.project.agent_runs
        .where(issue: issue, status: AgentRun::UNFINISHED_STATUSES)
        .order(created_at: :asc, id: :asc)
        .first
    end

    def dependencies
      @dependencies ||= issue.blocking_issues.includes(:project).to_a +
        issue.blocking_deployment_dependencies.includes(depends_on_issue: :project).to_a +
        issue.blocking_external_dependencies.to_a
    end

    def scanner_blockers
      @scanner_blockers ||= Issues::CloseoutStatus.scanner_verification_blockers(issue)
    end

    def enhancement_failure?
      issue.needs_input_questions.present? || issue.manual_review_reason.present? || issue.project.agent_runs.where(
        issue: issue, goal: "enhance_issue", status: "failed"
      ).exists?
    end
  end
end
