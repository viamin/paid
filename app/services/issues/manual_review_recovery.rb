# frozen_string_literal: true

module Issues
  # Derives manual-review recovery from durable state, never the explanatory
  # stop message. Inbox rendering and the mutation endpoint share this policy.
  # @spec OPERATOR-INBOX-002D ISSUE-REOPEN-REVIEW-005
  class ManualReviewRecovery
    Recovery = Data.define(:cause, :action, :message, :active_run, :blockers) do
      def enhancement? = action == :enhance
      def waiting_on_dependency? = action == :wait_for_dependency
      def reopen_review? = action == :record_reopen_review
      def active? = active_run.present?
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return active_recovery if active_run
      return reopen_recovery if issue.reopen_review_pending?
      return dependency_recovery if blockers.any?
      return scanner_recovery if scanner_blockers.any?
      return unknown_recovery if issue.manual_review_reason.blank?

      enhancement_recovery
    end

    private

    attr_reader :issue

    def active_run
      @active_run ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :asc).first
    end

    def blockers
      @blockers ||= issue.blocking_issues.to_a + issue.blocking_deployment_dependencies.to_a + issue.blocking_external_dependencies.to_a
    end

    def scanner_blockers
      @scanner_blockers ||= Issues::CloseoutStatus.scanner_verification_blockers(issue)
    end

    def active_recovery
      Recovery.new(cause: :active_run, action: :reuse_active_run,
        message: "Run ##{active_run.id} is already #{active_run.status}; review or reconcile it before starting more work.",
        active_run:, blockers: [])
    end

    def reopen_recovery
      Recovery.new(cause: :reopen_review, action: :record_reopen_review,
        message: "Validate the original closure and remaining scope before selecting a new continuation.", active_run: nil, blockers: [])
    end

    def dependency_recovery
      Recovery.new(cause: :dependency, action: :wait_for_dependency,
        message: "Work is waiting on an unresolved dependency; acknowledging this item does not waive that dependency.", active_run: nil, blockers:)
    end

    def scanner_recovery
      Recovery.new(cause: :scanner_recurrence, action: :review_scanner_recurrence,
        message: scanner_blockers.first.recovery, active_run: nil, blockers: scanner_blockers)
    end

    def enhancement_recovery
      Recovery.new(cause: :enhancement, action: :enhance,
        message: "Retry enhancement analysis after reviewing the recorded stop reason.", active_run: nil, blockers: [])
    end

    def unknown_recovery
      Recovery.new(cause: :unknown, action: :investigate,
        message: "The stop cause is unknown. Review the issue and prior runs before choosing a continuation.", active_run: nil, blockers: [])
    end
  end
end
