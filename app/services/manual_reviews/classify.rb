# frozen_string_literal: true

# Classifies a parked issue from durable producer evidence.  The free-form
# manual-review reason is deliberately display-only: it is not a workflow API.
module ManualReviews
  class Classify
    Recovery = Data.define(:cause, :action, :active_run, :blockers) do
      def active?
        active_run.present?
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(issue:)
      @issue = issue
    end

    # @spec OPERATOR-INBOX-002K ISSUE-REOPEN-REVIEW-005
    def call
      return recovery(:reopen_review, :record_decision) if issue.reopen_review_pending?
      return recovery(:dependency, :wait_for_dependency) if blockers.any?
      return recovery(:scanner_recurrence, :collect_scanner_evidence) if scanner_recurrence?
      return recovery(:enhancement, :retry_enhancement) if enhancement_provenance?

      recovery(:unknown, :investigate)
    end

    private

    attr_reader :issue

    def recovery(cause, action)
      Recovery.new(cause:, action:, active_run: active_run, blockers: blockers)
    end

    def active_run
      @active_run ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES)
        .order(created_at: :desc, id: :desc).first
    end

    def blockers
      @blockers ||= issue.blocking_issues.includes(:project).to_a
    end

    def scanner_recurrence?
      issue.code_scanning_remediation_attempts.latest_per_issue
        .where(status: "verification_failed").exists?
    end

    def enhancement_provenance?
      issue.needs_input_questions.present? || issue.agent_runs.where(goal: "enhance_issue").exists?
    end
  end
end
