# frozen_string_literal: true

module Issues
  # Selects a recovery from durable state, rather than trying to infer one from
  # the operator-facing reason text.  The reason remains evidence for people;
  # it is deliberately not a routing protocol.
  # @spec OPERATOR-INBOX-002D ISSUE-REOPEN-REVIEW-005
  class ManualReviewRecovery
    Result = Data.define(:cause, :action, :dependencies, :active_run) do
      def actionable? = action.present?
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return Result.new(cause: :active_work, action: nil, dependencies: [], active_run:) if active_run
      return Result.new(cause: :reopen_review, action: reopen_action, dependencies: [], active_run: nil) if issue.reopen_review_pending?
      return Result.new(cause: :dependency, action: nil, dependencies:, active_run: nil) if dependencies.any?
      return Result.new(cause: :scanner_recurrence, action: :retry_source_run, dependencies: [], active_run: nil) if scanner_recurrence?
      return Result.new(cause: :enhancement, action: :enhance, dependencies: [], active_run: nil) if enhancement_stop?

      Result.new(cause: :unknown, action: nil, dependencies: [], active_run: nil)
    end

    private

    attr_reader :issue

    def active_run
      @active_run ||= issue.agent_runs.where(status: AgentRun::DEDUP_BLOCKING_STATUSES).order(created_at: :desc).first
    end

    def reopen_action
      reopen_decision_current? ? :implementation : :record_reopen_decision
    end

    def reopen_decision_current?
      issue.project.account.account_activity_events.where(action: "issue.reopen_review_validated", subject: issue)
        .where("metadata ->> 'github_updated_at' = ?", issue.github_updated_at&.utc&.iso8601.to_s).exists?
    end

    def dependencies
      @dependencies ||= issue.issue_dependencies.includes(:depends_on_issue).filter_map do |dependency|
        if dependency.local?
          target = dependency.depends_on_issue
          "##{target.github_number}" if target && target.github_state == "open" && !target.paid_state.in?(Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES)
        elsif dependency.external?
          dependency.external_ref
        end
      end
    end

    def scanner_recurrence?
      issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE &&
        issue.code_scanning_remediation_attempts.latest_per_issue.where(status: "verification_failed").exists?
    end

    def enhancement_stop?
      issue.needs_input_questions.present? || issue.agent_runs.where(goal: "enhance_issue").exists?
    end
  end
end
