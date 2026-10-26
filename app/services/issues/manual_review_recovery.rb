# frozen_string_literal: true

module Issues
  # Classifies a manual-review stop from durable producer evidence.  It is
  # deliberately not a keyword classifier: the displayed reason is useful to
  # an operator, but it is untrusted as workflow authority.
  #
  # @spec OPERATOR-INBOX-002D
  class ManualReviewRecovery
    ENHANCEMENT_STOP_REASONS = [
      "Structured output failed validation.",
      "Paid reached the configured limit of enhancement re-evaluation rounds."
    ].freeze
    Recovery = Data.define(:cause, :action, :description, :blockers) do
      def enhancement? = cause == :enhancement
      def reopen? = cause == :reopen_review
      def dependency? = cause == :dependency
      def scanner? = cause == :scanner_recurrence
      def active_work? = cause == :active_work
      def unknown? = cause == :unknown
    end

    def self.call(issue:) = new(issue:).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return active_work_recovery if active_runs.any?
      return reopen_recovery if issue.reopen_review_pending?
      return dependency_recovery if dependency_blockers.any?
      return scanner_recovery if scanner_blockers.any?
      return active_work_recovery if active_runs.any?
      return enhancement_recovery if enhancement_provenance?

      unknown_recovery
    end

    private

    attr_reader :issue

    def reopen_recovery
      Recovery.new(:reopen_review, :validate_intent,
        "Record a revision-bound validation of the original closure and remaining scope before resuming implementation.", [])
    end

    def active_work_recovery
      Recovery.new(:active_work, :reconcile_active_work,
        "Existing queued or running work must be reconciled before this hold can be resumed.", active_runs)
    end

    def dependency_recovery
      Recovery.new(:dependency, :wait_for_dependency,
        "Work remains held until the listed dependency is resolved; acknowledging this item does not waive the dependency.", dependency_blockers)
    end

    def scanner_recovery
      Recovery.new(:scanner_recurrence, :authorize_remediation,
        "Review the scanner-confirmed recurrence and explicitly authorize remediation if new implementation is appropriate.", scanner_blockers)
    end

    def active_work_recovery
      Recovery.new(:active_work, :reconcile_existing_work,
        "Existing queued or running work must be reused or reconciled before another recovery action can start.", active_runs)
    end

    def enhancement_recovery
      Recovery.new(:enhancement, :retry_enhancement,
        "Retry issue analysis and enhancement using the existing question-and-answer flow.", [])
    end

    def unknown_recovery
      Recovery.new(:unknown, :investigate,
        "Paid retained this stop because its producer could not be identified. Inspect its evidence before choosing work.", [])
    end

    def dependency_blockers
      @dependency_blockers ||= issue.blocking_issues.order(:github_number).to_a + issue.blocking_external_dependencies.to_a
    end

    def scanner_blockers
      @scanner_blockers ||= CloseoutStatus.scanner_verification_blockers(issue)
    end

    def active_runs
      @active_runs ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :desc).to_a
    end

    def active_runs
      @active_runs ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(:created_at).map do |run|
        { label: "#{run.goal.tr('_', ' ')} run ##{run.id} (#{run.status})", url: "/projects/#{issue.project_id}/agent_runs/#{run.id}" }
      end
    end

    def enhancement_provenance?
      issue.needs_input_questions.present? || issue.agent_runs.where(goal: "enhance_issue").exists? ||
        ENHANCEMENT_STOP_REASONS.any? { |reason| issue.manual_review_reason.to_s.start_with?(reason) }
    end
  end
end
