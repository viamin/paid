# frozen_string_literal: true

module Inbox
  # Chooses a manual-review recovery from durable provenance rather than from
  # the human-readable stop message. The same object is used by the Inbox and
  # the mutation endpoint so a rendered action cannot disagree with admission.
  # @spec OPERATOR-INBOX-002D @spec ISSUE-REOPEN-REVIEW-005
  class ManualReviewRecovery
    Recovery = Data.define(:cause, :action, :active_run, :dependencies, :scanner_attempt)

    def self.call(...)
      new(...).call
    end

    def self.record_reopen_decision!(issue:, actor:, reason:, revision:)
      new(issue:).record_reopen_decision!(actor:, reason:, revision:)
    end

    def initialize(issue:)
      @issue = issue
    end

    def call
      return Recovery.new(cause: :active_work, action: :reuse_run, active_run:, dependencies: [], scanner_attempt: nil) if active_run
      return Recovery.new(cause: :reopen_review, action: :record_reopen_decision, active_run: nil, dependencies: [], scanner_attempt: nil) if reopen_review_pending?
      return Recovery.new(cause: :dependency, action: :wait_for_dependency, active_run: nil, dependencies:, scanner_attempt: nil) if dependencies.any?
      return Recovery.new(cause: :scanner_recurrence, action: :collect_scanner_evidence, active_run: nil, dependencies: [], scanner_attempt:) if scanner_attempt
      return Recovery.new(cause: :enhancement_questions, action: :answer_questions, active_run: nil, dependencies: [], scanner_attempt: nil) if Inbox::Queue.questions_for(issue).any?
      return Recovery.new(cause: :enhancement, action: :retry_enhancement, active_run: nil, dependencies: [], scanner_attempt: nil) if latest_run&.enhance_issue_goal?
      return Recovery.new(cause: :technical_failure, action: :retry_failed_run, active_run: nil, dependencies: [], scanner_attempt: nil) if technical_failure_reason?
      return Recovery.new(cause: :enhancement, action: :retry_enhancement, active_run: nil, dependencies: [], scanner_attempt: nil) if enhancement_stop_reason?

      Recovery.new(cause: :unknown, action: :investigate, active_run: nil, dependencies: [], scanner_attempt: nil)
    end

    def record_reopen_decision!(actor:, reason:, revision:)
      raise ArgumentError, "A reopen-review reason is required." if reason.blank?
      raise ArgumentError, "The issue changed since this review started. Refresh and validate the current revision." unless revision == issue.github_updated_at&.iso8601

      Audit::RecordEvent.call(
        action: "issue.reopen_review_validated",
        account: issue.project.account,
        actor: actor,
        subject: issue,
        metadata: { reason: reason, github_updated_at: revision }
      )
    end

    private

    attr_reader :issue

    def active_run
      @active_run ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :desc, id: :desc).first
    end

    def latest_run
      @latest_run ||= issue.agent_runs.order(created_at: :desc, id: :desc).first
    end

    def dependencies
      @dependencies ||= issue.blocking_issues.to_a + issue.blocking_deployment_dependencies.includes(:depends_on_issue).to_a + issue.blocking_external_dependencies.to_a
    end

    def scanner_attempt
      @scanner_attempt ||= issue.code_scanning_remediation_attempts.latest_per_issue.find_by(status: "verification_failed")
    end

    def reopen_review_pending?
      return false unless issue.reopen_review_pending?

      !AccountActivityEvent.where(account: issue.project.account, subject: issue, action: "issue.reopen_review_validated")
        .where("metadata ->> 'github_updated_at' = ?", issue.github_updated_at&.iso8601).exists?
    end

    def technical_failure_reason?
      issue.manual_review_reason.in?([
        "Paid could not validate the enhancement agent's structured output.",
        "Enhancement transport failed.",
        "Structured enhancement output was invalid."
      ])
    end

    def enhancement_stop_reason?
      issue.manual_review_reason == "Round limit reached." ||
        issue.manual_review_reason.to_s.start_with?("Paid reached the configured limit of")
    end
  end
end
