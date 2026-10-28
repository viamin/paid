# frozen_string_literal: true

module Issues
  # One authorized mutation path for reopen-review decisions. It records the
  # current revision and reconciles active work while holding the issue lock.
  # @spec OPERATOR-INBOX-002L @spec ISSUE-REOPEN-REVIEW-005
  class RecoverManualReview
    DECISIONS = %w[closure_valid remaining_work].freeze
    Result = Data.define(:code, :message, :agent_run) do
      def success? = code.nil?
    end

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, decision:, reason:)
      @issue = issue
      @actor = actor
      @decision = decision.to_s
      @reason = reason.to_s.strip
    end

    def call
      return failure(:invalid_decision, "Choose whether the original closure remains valid or work remains.") unless decision.in?(DECISIONS)
      return failure(:invalid_reason, "A reopen-review reason is required.") if reason.blank?

      issue.with_lock do
        issue.reload
        return failure(:stale_review, "This issue is no longer waiting for reopen review.") unless issue.reopen_review_pending?
        return dependency_failure if unresolved_dependencies.any?

        run = decision == "remaining_work" ? reconcile_implementation_run : nil
        return run if run.is_a?(Result)

        revision = issue.reopen_review_revision
        issue.update!(paid_state: decision == "closure_valid" ? "completed" : "in_progress")
        record_decision(revision, run)
        ProcessRunQueueJob.perform_later if run
        success(run)
      end
    rescue ActiveRecord::RecordNotUnique
      active = active_runs.find_by(goal: "create_pr")
      active ? success(active) : failure(:concurrent_recovery, "Recovery changed concurrently; refresh the Inbox.")
    end

    private

    attr_reader :actor, :decision, :issue, :reason

    def unresolved_dependencies
      issue.dependencies.where(github_state: "open")
        .where.not(paid_state: Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES)
    end

    def dependency_failure
      numbers = unresolved_dependencies.pluck(:github_number).map { |number| "##{number}" }
      failure(:unresolved_dependency, "Resolve #{numbers.to_sentence} before continuing this issue.")
    end

    def reconcile_implementation_run
      runs = active_runs.to_a
      compatible = runs.find { |run| run.goal == "create_pr" }
      return compatible if compatible && runs.one?
      return failure(:incompatible_active_run, active_run_message(runs)) if runs.any?

      runner_id, agent_type = AgentRuns::RunnerResolver.call(project: issue.project, goal: "create_pr")
      issue.agent_runs.create!(project: issue.project, initiating_user: actor, runner_id:, agent_type:,
        goal: "create_pr", trigger_type: "manual", review_depth_snapshot: issue.project.effective_review_depth,
        status: "queued")
    end

    def active_runs
      issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES)
    end

    def active_run_message(runs)
      labels = runs.map { |run| "run ##{run.id} (#{run.goal})" }
      "Reconcile active #{labels.to_sentence} before continuing implementation."
    end

    def record_decision(revision, run)
      Audit::RecordEvent.call(action: "issue.reopen_review_resolved", actor:, subject: issue,
        metadata: { decision:, reason:, revision:, reopen_reason: issue.reopen_reason,
                    reopened_at: issue.reopened_at&.utc&.iso8601, agent_run_id: run&.id }.compact)
    end

    def success(run) = Result.new(code: nil, message: run ? "Implementation continuation queued." : "Reopen review recorded as complete.", agent_run: run)
    def failure(code, message) = Result.new(code:, message:, agent_run: nil)
  end
end
