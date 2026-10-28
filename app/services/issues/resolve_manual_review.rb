# frozen_string_literal: true

module Issues
  # Authorized, idempotent cause-specific transition out of manual review.
  # Callers supply the normal run creator so runner/admission policy remains
  # shared with every other manual run surface.
  # @spec ISSUE-REOPEN-REVIEW-005 @spec OPERATOR-INBOX-002D
  class ResolveManualReview
    Result = Data.define(:status, :message, :run) do
      def success? = status.in?([ :queued, :reused ])
    end

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, action:, revision:, reason:, continuation:, run_creator:)
      @issue = issue
      @actor = actor
      @action = action.to_s
      @revision = revision
      @reason = reason
      @continuation = continuation.to_s
      @run_creator = run_creator
    end

    def call
      recovery = Inbox::ManualReviewRecovery.call(issue)
      return failure(conflict_message(recovery)) unless recovery.causes.one? && recovery.primary.action&.to_s == action

      goal = recovery_goal(recovery)
      return goal if goal.is_a?(Result)
      unless CostBudgets::Check.call(issue.project)[:allowed]
        return failure("Your project's AI budget has been reached. Please adjust your budget settings or try again later.")
      end

      queue(goal, recovery)
    end

    private

    attr_reader :issue, :actor, :action, :revision, :reason, :continuation, :run_creator

    def recovery_goal(recovery)
      return "enhance_issue" if recovery.primary.action == :retry_analysis
      return "create_pr" if recovery.primary.action == :resume_implementation
      return failure("This manual-review cause has no supported recovery action.") unless recovery.primary.action == :record_reopen_decision
      return failure("This issue changed after the review form loaded. Review the current revision and try again.") if revision.blank? || revision != recovery.required_revision
      return failure("Provide the intent-validation decision and reason.") if reason.blank?

      { "implementation" => "create_pr", "analysis" => "enhance_issue" }.fetch(continuation) do
        return failure("Select how work should continue.")
      end
    end

    def queue(goal, recovery)
      run = nil
      issue.with_lock do
        issue.reload
        return failure("This issue is no longer waiting for manual review.") unless issue.paid_state == "manual_review"

        active = issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(:id).first
        if active&.goal == goal
          record_decision(goal, recovery) if recovery.primary.type == :reopen_review
          issue.update!(paid_state: "in_progress")
          return reused(active)
        end
        return failure("Run ##{active.id} is already #{active.status} for #{active.goal}. Reconcile it before clearing this hold.") if active

        run = run_creator.call(goal:)
        record_decision(goal, recovery) if recovery.primary.type == :reopen_review
        issue.update!(paid_state: "in_progress")
      end
      ProcessRunQueueJob.perform_later
      Result.new(status: :queued, message: "#{action_label(goal)} queued as run ##{run.id}; the manual-review hold was cleared.", run:)
    rescue ActiveRecord::RecordNotUnique
      failure("Compatible work was queued concurrently. Refresh the Inbox before trying again.")
    end

    def record_decision(goal, recovery)
      issue.project.account.account_activity_events.create!(
        action: "issue.reopen_review_resolved", actor:, subject: issue,
        metadata: { decision: goal == "create_pr" ? "resume_implementation" : "retry_analysis",
                    reason:, revision: recovery.required_revision, prior_closed_at: issue.closed_at&.iso8601,
                    reopen_reason: issue.reopen_reason }.compact
      )
    end

    def reused(run)
      Result.new(status: :reused,
        message: "Reusing compatible run ##{run.id} (#{run.goal}, #{run.status}); no second run was created.", run:)
    end

    def conflict_message(recovery)
      return "Resolve the recorded dependency before continuing; an acknowledgement cannot waive it." if recovery.causes.any? { |cause| cause.type == :dependency }
      return "Reconcile work already in flight before clearing this hold." if recovery.active_runs.any?

      "This manual-review cause has no supported automatic recovery. The hold was not cleared."
    end

    def action_label(goal) = goal == "enhance_issue" ? "Analysis retry" : "Implementation"
    def failure(message) = Result.new(status: :invalid, message:, run: nil)
  end
end
