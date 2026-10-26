# frozen_string_literal: true

module Issues
  # Classifies a manual-review item from durable records, never from prose in
  # its reason. The Inbox uses this same result for its copy and its command,
  # so a new action cannot silently reinterpret a hold.
  # @spec OPERATOR-INBOX-002D @spec ISSUE-REOPEN-REVIEW-005
  class ManualReviewRecovery
    Result = Data.define(:cause, :goal, :active_run, :dependency, :revision) do
      def actionable? = goal.present? && active_run.nil?
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      Result.new(
        cause: cause,
        goal: goal,
        active_run: active_run,
        dependency: dependency,
        revision: issue.github_updated_at&.iso8601
      )
    end

    private

    attr_reader :issue

    def cause
      return :reopen_review if issue.reopen_review_pending?
      return :dependency if dependency
      return :scanner_recurrence if scanner_recurrence?
      return :enhancement if latest_run&.goal == "enhance_issue"
      return :enhancement if legacy_enhancement_stop?
      return :technical_recovery if latest_run&.status == "failed"

      :unknown
    end

    def goal
      {
        reopen_review: "analyze_issue",
        scanner_recurrence: "create_pr",
        enhancement: "enhance_issue",
        technical_recovery: latest_run&.goal
      }.fetch(cause, nil)
    end

    def dependency
      issue.blocking_issues.first || issue.blocking_deployment_dependencies.first&.depends_on_issue ||
        issue.blocking_external_dependencies.first&.depends_on_issue
    end

    def scanner_recurrence?
      Issues::CloseoutStatus.scanner_verification_blockers(issue).any? do |blocker|
        blocker.code == :scanner_verification_failed
      end
    end

    def latest_run
      @latest_run ||= issue.agent_runs.order(created_at: :desc).first
    end

    # Pre-provenance rows have no producing-run relationship to inspect. Keep
    # the two stable, producer-owned stop messages actionable while leaving
    # every other legacy reason visibly unknown rather than guessing from text.
    def legacy_enhancement_stop?
      reason = issue.manual_review_reason.to_s
      reason.in?([ "Structured output failed validation.", "Round limit reached." ]) ||
        reason.start_with?("Paid reached the configured limit of enhancement re-evaluation rounds")
    end

    def active_run
      issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :asc).first
    end
  end
end
