# frozen_string_literal: true

module ManualReviews
  # Identifies a manual-review recovery path from persisted operational
  # evidence.  It deliberately does not infer a cause from natural-language
  # issue content: the stop producer, dependency graph, scanner attempt, and
  # active run are the authority.
  # @spec OPERATOR-INBOX-002D ISSUE-REOPEN-REVIEW-005
  class Classify
    Result = Data.define(:cause, :blockers, :active_runs) do
      def reopen_review?
        cause == :reopen_review
      end

      def dependency?
        cause == :dependency
      end

      def scanner_recurrence?
        cause == :scanner_recurrence
      end

      def enhancement?
        cause == :enhancement
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(issue:)
      @issue = issue
    end

    def call
      Result.new(cause:, blockers:, active_runs:)
    end

    private

    attr_reader :issue

    def cause
      return :reopen_review if issue.reopen_review_pending?
      return :dependency if blockers.any? { |blocker| blocker.code == :unmet_prerequisites }
      return :scanner_recurrence if blockers.any? { |blocker| blocker.code.to_s.start_with?("scanner_verification_") }
      return :enhancement if issue.needs_input_questions.present? || latest_run&.enhance_issue_goal? || enhancement_stop?

      :unknown
    end

    def blockers
      @blockers ||= Issues::CloseoutStatus.call(issue).blockers
    end

    def active_runs
      @active_runs ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(:created_at, :id).to_a
    end

    def latest_run
      @latest_run ||= issue.agent_runs.order(created_at: :desc, id: :desc).first
    end

    # These are the exact, producer-owned stop records written by
    # EnhanceIssueActivity. They are provenance codes encoded before this
    # classifier existed, not a judgement about arbitrary operator prose.
    def enhancement_stop?
      issue.manual_review_reason.to_s.start_with?("Paid reached the configured limit of ") ||
        [
          "Paid could not validate the enhancement agent's structured output.",
          "Structured enhancement output was invalid.",
          "Structured output failed validation."
        ].include?(issue.manual_review_reason)
    end
  end
end
