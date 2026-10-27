# frozen_string_literal: true

module Issues
  # Resumes an issue that is parked in `manual_review` by routing it to the
  # recovery its cause supports (#4640).
  #
  # The service is the single authorized entry point for that recovery: the
  # Inbox pane, the API and the chat all call it, so an enhancement retry is
  # never offered for a reopen review or a dependency wait, and a run is never
  # queued while an incompatible one is still active.
  #
  # @spec MANUAL-REVIEW-RECOVERY-004 @spec MANUAL-REVIEW-RECOVERY-005
  class ResumeManualReview
    Result = Struct.new(:issue, :agent_run, :code, :message, keyword_init: true) do
      def success? = code.nil?
    end

    ENHANCEMENT_GOAL = "enhance_issue"
    IMPLEMENTATION_GOAL = "create_pr"

    # Raised by an injected run factory when no run could be created. The
    # message is the operator-facing explanation.
    RunCreationFailed = Class.new(StandardError)

    def self.call(...) = new(...).call

    # +create_run+ is the caller's run factory. The web Inbox injects the
    # controller's own run creation (its runner selection and activation
    # rules); other callers get the shared runner resolver.
    def initialize(issue:, actor:, goal: nil, create_run: nil)
      @issue = issue
      @actor = actor
      @goal = goal.presence
      @create_run = create_run
    end

    def call
      return failure(:not_authorized, "You are not authorized to resume this issue.") unless authorized?
      return failure(:not_in_manual_review, "This issue is no longer waiting for manual review.") unless parked?

      cause = Inbox::ManualReviewCause.call(issue:)
      allowed = allowed_goals(cause)
      refusal = goal_refusal(cause, allowed)
      return refusal if refusal

      resolved_goal = goal.presence || allowed.first
      conflict = in_flight_conflict(resolved_goal)
      return conflict if conflict

      queue_run(resolved_goal)
    end

    private

    attr_reader :actor, :create_run, :goal, :issue

    def authorized?
      return false if actor.blank?

      account_id = issue.project&.account_id
      account_id.present? && account_id == actor.account_id
    end

    def parked?
      issue.paid_state == "manual_review"
    end

    # Each cause names the continuations Paid supports for it. A cause with
    # no supported continuation refuses instead of falling back to a generic
    # enhancement retry.
    def allowed_goals(cause)
      case cause.code
      when Inbox::ManualReviewCause::REOPEN_REVIEW then reopen_review_goals
      when Inbox::ManualReviewCause::DEPENDENCY_WAIT then []
      when Inbox::ManualReviewCause::SCANNER_RECURRENCE then [ IMPLEMENTATION_GOAL ]
      else [ ENHANCEMENT_GOAL ]
      end
    end

    def reopen_review_goals
      return [] unless issue.reopen_review_decided?
      return [] if issue.reopen_review_stale?

      issue.reopen_review_decision == Issues::ResolveReopenReview::SUPERSEDED ? [] : [ ENHANCEMENT_GOAL, IMPLEMENTATION_GOAL ]
    end

    def goal_refusal(cause, allowed)
      if allowed.empty?
        return failure(:dependency_wait, dependency_wait_message(cause)) if cause.dependency_wait?
        return failure(:intent_validation_required, intent_validation_message) if cause.reopen_review?
        return failure(:no_supported_continuation, "This issue has no supported continuation until its review is resolved.")
      end
      return nil if goal.blank? || allowed.include?(goal)

      failure(:unsupported_goal, "This recovery does not support a #{goal} run. Supported: #{allowed.join(', ')}.")
    end

    def dependency_wait_message(cause)
      hold = cause.holds.find { |candidate| candidate.code == Inbox::ManualReviewCause::DEPENDENCY_WAIT }
      hold&.message || "This issue is waiting on unresolved dependency work."
    end

    def intent_validation_message
      "Record the reopen-review validation before resuming this issue."
    end

    # Work that is already queued or running is inspected before a new run is
    # created: a compatible run is reused, an incompatible one is reported
    # with its identity so the operator can reconcile it. The hold is never
    # cleared while an incompatible run remains queued.
    def in_flight_conflict(resolved_goal)
      runs = in_flight_runs
      return nil if runs.empty?

      return nil if runs.any? { |run| run.goal == resolved_goal }

      run = runs.first
      failure(:conflicting_run, "Run ##{run.id} (#{run.goal}) is already #{run.status} for this issue. " \
        "Reuse it or reconcile it before starting another one.")
    end

    def in_flight_runs
      @in_flight_runs ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :asc, id: :asc).to_a
    end

    def queue_run(resolved_goal)
      existing = in_flight_runs.find { |run| run.goal == resolved_goal }
      return reuse_run(existing) if existing

      budget = CostBudgets::Check.call(issue.project)
      unless budget[:allowed]
        return failure(:budget_exhausted, "Your project's AI budget has been reached. Please adjust your budget settings or try again later.")
      end

      create_and_flip(resolved_goal)
    end

    def reuse_run(run)
      issue.update!(paid_state: "in_progress")
      Result.new(issue:, agent_run: run,
        message: "Run ##{run.id} (#{run.goal}) was already queued for this issue; reusing it.")
    end

    def create_and_flip(resolved_goal)
      agent_run = nil
      ActiveRecord::Base.transaction do
        agent_run = build_run(resolved_goal)
        return failure(:no_runner, "No runnable runner could be resolved for this project.") if agent_run.nil?

        issue.update!(paid_state: "in_progress")
      end

      ProcessRunQueueJob.perform_later
      record_audit_event(agent_run)
      Result.new(issue:, agent_run:, message: queued_message(resolved_goal))
    rescue ActiveRecord::RecordNotUnique
      failure(:conflicting_run, "Another run for this issue is already queued. Reuse it or reconcile it before starting another one.")
    rescue RunCreationFailed => e
      failure(:no_runner, e.message)
    end

    def build_run(resolved_goal)
      return create_run.call(resolved_goal) if create_run

      runner_id, agent_type = AgentRuns::RunnerResolver.call(project: issue.project, goal: resolved_goal)
      return nil if runner_id.blank?

      Issues::ActivatePaid.call(project: issue.project, issue: issue)
      AgentRun.create!(
        project: issue.project,
        issue: issue,
        initiating_user: actor,
        runner_id: runner_id,
        agent_type: agent_type,
        goal: resolved_goal,
        trigger_type: "manual",
        review_depth_snapshot: issue.project.effective_review_depth,
        status: "queued"
      )
    end

    def queued_message(resolved_goal)
      return "Agent run queued for issue enhancement." if resolved_goal == ENHANCEMENT_GOAL

      "Agent run queued to resume implementation."
    end

    def record_audit_event(agent_run)
      Audit::RecordEvent.call(
        action: "issue.manual_review_resumed",
        actor: actor,
        subject: issue,
        metadata: { "agent_run_id" => agent_run.id, "goal" => agent_run.goal }
      )
    end

    def failure(code, message) = Result.new(code:, message:)
  end
end
