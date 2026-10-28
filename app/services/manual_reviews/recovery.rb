# frozen_string_literal: true

module ManualReviews
  # Maps durable, structured manual-review provenance to the one recovery
  # action that can safely act on it.  Reasons remain operator-facing evidence;
  # they are intentionally not parsed to decide workflow behavior.
  class Recovery
    Result = Data.define(:cause, :blockers, :active_runs) do
      def retries_enhancement? = cause == :enhancement
      def records_decision? = cause == :reopen_review
      def resumes_implementation? = retries_enhancement? || records_decision?
      def waits_for_dependency? = cause == :dependency_wait
      def scanner_recurrence? = cause == :scanner_recurrence
      def unknown? = cause == :unknown
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    # @spec ISSUE-REOPEN-REVIEW-005 OPERATOR-INBOX-002D
    def call
      Result.new(cause:, blockers:, active_runs:)
    end

    private

    attr_reader :issue

    def cause
      return :reopen_review if issue.reopen_review_pending?
      return :dependency_wait if blockers.any?
      return :scanner_recurrence if scanner_recurrence?
      return :enhancement if enhancement_provenance?

      :unknown
    end

    def blockers
      @blockers ||= issue.blocking_issues.to_a +
        issue.blocking_deployment_dependencies.map(&:depends_on_issue) +
        issue.blocking_external_dependencies.to_a
    end

    def scanner_recurrence?
      issue.code_scanning_remediation_attempts.latest_per_issue
        .where(status: "verification_failed").exists?
    end

    def enhancement_provenance?
      issue.agent_runs.where(goal: "enhance_issue").exists? ||
        Inbox::Queue.questions_for(issue).any?
    end

    def active_runs
      issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(:id).to_a
    end
  end
end
