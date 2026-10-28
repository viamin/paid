# frozen_string_literal: true

module Issues
  # The single state transition for a revision-bound reopen-review decision.
  # Authorization stays at each transport boundary; this service enforces the
  # shared evidence, concurrency, dependency, and audit contract.
  # @spec ISSUE-REOPEN-REVIEW-005 @spec OPERATOR-INBOX-002I
  class ResolveReopenReview
    Result = Data.define(:status, :message) do
      def success? = status == :resolved
    end

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, decision:, reason:, evidence_revision:)
      @issue = issue
      @actor = actor
      @decision = decision
      @reason = reason.to_s.strip
      @evidence_revision = evidence_revision.to_s
    end

    def call
      return failure("Select resume implementation and explain the revision-bound intent decision.") unless valid_decision?
      return failure("The issue changed after this review loaded. Refresh the Inbox and validate the current revision.") unless current_revision?
      return failure(active_run_message) if active_runs.any?
      return failure("Unresolved dependencies still block this issue; the review decision did not waive them.") if dependency_blocked?

      resolve!
      Result.new(status: :resolved,
        message: "Intent validation recorded. Implementation can proceed through normal admission controls.")
    rescue ActiveRecord::StaleObjectError
      failure("This issue is no longer waiting for reopen review.")
    end

    private

    attr_reader :actor, :decision, :evidence_revision, :issue, :reason

    def valid_decision? = decision == "resume_implementation" && reason.present?

    def current_revision?
      ActiveSupport::SecurityUtils.secure_compare(evidence_revision, revision)
    end

    def revision = (issue.github_updated_at || issue.updated_at).iso8601(6)

    def active_runs
      @active_runs ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(:id).to_a
    end

    def active_run_message
      "Work is already queued or running for this issue; reconcile run ##{active_runs.first.id} first."
    end

    def dependency_blocked?
      issue.blocking_issues.exists? || issue.blocking_external_dependencies.exists? ||
        issue.blocking_deployment_dependencies.exists?
    end

    def resolve!
      Issue.transaction do
        issue.lock!
        raise ActiveRecord::StaleObjectError.new(issue, "resolve reopen review") unless issue.reopen_review_pending?

        issue.update!(paid_state: "new")
        issue.project.account.account_activity_events.create!(
          action: "issue.reopen_review_resolved", actor:, subject: issue,
          metadata: { decision:, reason:, evidence_revision: }
        )
      end
    end

    def failure(message) = Result.new(status: :invalid, message:)
  end
end
