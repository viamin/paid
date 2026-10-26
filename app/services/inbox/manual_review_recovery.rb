# frozen_string_literal: true

module Inbox
  # Classifies a manual-review hold from durable producer evidence.  This is
  # deliberately structural: it does not infer a recovery action from prose.
  # @spec MANUAL-REVIEW-RECOVERY-001 @spec MANUAL-REVIEW-RECOVERY-002
  class ManualReviewRecovery
    Recovery = Data.define(:cause, :dependency, :active_run) do
      def resumable?
        cause == :enhancement && active_run.nil?
      end

      def action
        return :wait_for_dependency if cause == :dependency
        return :inspect_scanner_evidence if cause == :scanner_recurrence
        return :validate_reopen_intent if cause == :reopen_review
        return :reconcile_active_run if active_run
        return :retry_enhancement if cause == :enhancement

        :investigate_unknown
      end
    end

    def self.call(issue) = new(issue).call

    def initialize(issue)
      @issue = issue
    end

    def call
      Recovery.new(cause:, dependency:, active_run:)
    end

    private

    attr_reader :issue

    def cause
      return :reopen_review if issue.reopen_review_pending?
      return :dependency if dependency
      return :scanner_recurrence if issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE
      return :enhancement if enhancement_provenance?

      :unknown
    end

    def dependency
      @dependency ||= issue.blocking_issues.first unless issue.ready_to_work?
    end

    def active_run
      @active_run ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :desc, id: :desc).first
    end

    def enhancement_provenance?
      issue.needs_input_questions.present? ||
        issue.agent_runs.where(goal: "enhance_issue").exists? ||
        enhancement_stop_reason?
    end

    # These are producer-owned reason formats emitted by the existing
    # enhancement stop paths.  They are protocol values, not a semantic guess
    # about an operator's free-form text.
    def enhancement_stop_reason?
      issue.manual_review_reason.to_s.start_with?(
        "Paid reached the configured limit of enhancement",
        "Paid has reached the configured limit of enhancement",
        "Round limit reached.",
        "Structured enhancement output was invalid.",
        "Enhancement transport failed.",
        "Paid could not validate the enhancement agent's structured output."
      )
    end
  end
end
