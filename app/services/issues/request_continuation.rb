# frozen_string_literal: true

module Issues
  # Deliberate continuation of an issue stalled behind terminal closeout
  # evidence (merged partial PR / no-code outcome). Persists the scoped
  # authorization (actor, reason, outcome-generation digest) and queues
  # exactly one create_pr run for it, in a single transaction (#4120).
  #
  # Admission reuses the auto-pick eligibility guards: the request only lifts
  # the merged-PR and no-code guards for this one issue (via
  # `DefaultCandidateSource.eligible_scope(continuation_authorized_issue_ids:)`
  # at dequeue), so dependencies, trust, feature gates, budgets, pauses,
  # skip labels, and active-run uniqueness all still apply, with the blocker
  # explained to the user.
  # @spec PARTIAL-CLOSEOUT-003 @spec PARTIAL-CLOSEOUT-004 @spec PARTIAL-CLOSEOUT-008
  class RequestContinuation
    Result = Struct.new(:request, :agent_run, :code, :message, keyword_init: true) do
      def success? = code.nil?
    end

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, reason:, origin: :operator)
      @issue = issue
      @actor = actor
      @reason = reason.to_s.strip
      @origin = origin.to_sym
    end

    def call
      return failure(:invalid_reason, "A continuation reason is required.") if reason.blank?
      return failure(:automation_disabled, "Automatic continuation is disabled for this project.") if automatic? && !auto_pick_project_open?

      issue.with_lock do
        existing = IssueContinuationRequest.open_for_issue(issue)
        return success(existing, existing.agent_runs.first) if existing

        status = CloseoutStatus.call(issue)
        refusal = refusal_for(status)
        return refusal if refusal

        budget = CostBudgets::Check.call(issue.project)
        return failure(:budget_exhausted, "The project's AI budget has been reached (#{budget[:reason]}).") unless budget[:allowed]

        create_request_and_run(status)
      end
    rescue ActiveRecord::RecordNotUnique => e
      raise unless duplicate_request?(e)

      existing = IssueContinuationRequest.open_for_issue(issue)
      return success(existing, existing.agent_runs.first) if existing

      raise
    end

    private

    attr_reader :actor, :issue, :origin, :reason

    def refusal_for(status)
      unless status.evidence.present?
        return failure(:not_stalled, "This issue has no terminal closeout evidence, so there is nothing to continue past.")
      end
      if status.open_request.present?
        return nil # handled by the open-request fast path; defensive only
      end
      if status.resolved_current_generation
        return failure(:not_stalled, "This issue was already resolved complete against the current evidence.")
      end

      blocker = status.blockers.first
      return failure(blocker.code, status.reason) if blocker
      if status.admissible
        return failure(:not_stalled, "This issue is already admissible to automatic scheduling; there is nothing to continue past.")
      end

      nil
    end

    def create_request_and_run(status)
      request = nil
      run = nil
      ActiveRecord::Base.transaction do
        request = IssueContinuationRequest.create!(
          issue: issue,
          project: issue.project,
          requested_by: actor,
          reason: reason,
          evidence: evidence_snapshot(status.evidence),
          evidence_digest: status.evidence.digest
        )
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project: issue.project, goal: "create_pr")
        run = AgentRun.create!(
          project: issue.project,
          issue: issue,
          initiating_user: actor,
          runner_id: runner_id,
          agent_type: agent_type,
          goal: "create_pr",
          trigger_type: trigger_type,
          auto_pick: automatic?,
          review_depth_snapshot: issue.project.effective_review_depth,
          continuation_request: request,
          status: "queued"
        )
      end

      Audit::RecordEvent.call(
        action: "issue.continuation_requested",
        actor: actor,
        subject: issue,
        metadata: {
          issue_continuation_request_id: request.id,
          agent_run_id: run.id,
          evidence_digest: request.evidence_digest
        }
      )
      ProcessRunQueueJob.perform_later

      Rails.logger.info(
        message: "issues.continuation_requested",
        component: "agent_execution",
        issue_id: issue.id,
        project_id: issue.project_id,
        issue_number: issue.github_number,
        request_id: request.id,
        agent_run_id: run.id,
        actor_id: actor&.id
      )

      success(request, run)
    end

    def evidence_snapshot(evidence)
      {
        "merged_prs" => evidence.merged_prs.map { |pr| { "number" => pr.number, "url" => pr.url, "run_id" => pr.run_id } },
        "no_code_required_at" => evidence.no_code_required_at&.utc&.iso8601
      }
    end

    def success(request, agent_run) = Result.new(request: request, agent_run: agent_run)
    def failure(code, message) = Result.new(code: code, message: message)

    def automatic? = origin == :automatic
    def trigger_type = automatic? ? "automatic" : "manual"

    def auto_pick_project_open?
      AutoPickProjectGate.call(issue.project)
    end

    def duplicate_request?(error)
      (error.cause&.message || error.message).include?("index_issue_continuation_requests_open_per_issue")
    end
  end
end
