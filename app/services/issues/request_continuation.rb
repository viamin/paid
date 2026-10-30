# frozen_string_literal: true

module Issues
  # Deliberate continuation of an issue stalled behind terminal closeout
  # evidence (merged partial PR / no-code outcome). Persists the scoped
  # authorization (actor, reason, outcome-generation digest, continuation
  # mode) and queues exactly one run for it, in a single transaction (#4120).
  # The mode keeps distinct authorizations distinct: implementation
  # continuations queue a create_pr run, acceptance audits an analyze_issue
  # run, and deduplication never converts one into the other.
  #
  # Admission reuses the auto-pick eligibility guards: the request only lifts
  # the merged-PR and no-code guards for this one issue (via
  # `DefaultCandidateSource.eligible_scope(continuation_authorized_issue_ids:)`
  # at dequeue), so dependencies, trust, feature gates, budgets, pauses,
  # skip labels, and active-run uniqueness all still apply, with the blocker
  # explained to the user.
  # @spec PARTIAL-CLOSEOUT-003 @spec PARTIAL-CLOSEOUT-004 @spec PARTIAL-CLOSEOUT-008
  # @spec PARTIAL-CLOSEOUT-006 @spec PARTIAL-CLOSEOUT-027 @spec PARTIAL-CLOSEOUT-037
  class RequestContinuation
    Result = Struct.new(:request, :agent_run, :code, :message, keyword_init: true) do
      def success? = code.nil?
    end

    MODE_LABELS = {
      "implementation" => "implementation continuation",
      "acceptance_audit" => "acceptance audit"
    }.freeze

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, reason:, origin: :operator, goal: "create_pr", continuation_mode: "implementation")
      @issue = issue
      @actor = actor
      @reason = reason.to_s.strip
      @origin = origin.to_sym
      @goal = goal
      @continuation_mode = continuation_mode
    end

    def call
      return failure(:invalid_reason, "A continuation reason is required.") if reason.blank?
      return failure(:automation_disabled, "Automatic continuation is disabled for this project.") if automatic? && !auto_pick_project_open?

      issue.with_lock do
        if issue.closeout_closing?
          return failure(:closeout_closing, "GitHub closure is in progress; retry continuation only if the close action fails.")
        end

        existing = IssueContinuationRequest.open_for_issue(issue)
        return dedupe_or_refuse(existing) if existing

        clear_legacy_resolution_with_unmet_work!
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
      return dedupe_or_refuse(existing) if existing

      raise
    end

    private

    attr_reader :actor, :continuation_mode, :goal, :issue, :origin, :reason

    # The one-open-request-per-issue dedup only spans the same operation: an
    # open implementation continuation is not an acceptance-audit request and
    # vice versa, so a mismatched open authorization is refused rather than
    # reported as the requested operation (#4597 review).
    # @spec PARTIAL-CLOSEOUT-027
    def dedupe_or_refuse(existing)
      return success(existing, existing.agent_runs.first) if authorizes_requested_operation?(existing)

      failure(:conflicting_open_request, conflict_message(existing))
    end

    def authorizes_requested_operation?(existing)
      return false unless persisted_mode(existing) == continuation_mode

      existing_run = existing.agent_runs.first
      existing_run.nil? || existing_run.goal == goal
    end

    # Requests persisted before continuation modes existed can only be
    # implementation continuations, so a missing mode reads as implementation.
    def persisted_mode(existing)
      existing.evidence["continuation_mode"] || "implementation"
    end

    def conflict_message(existing)
      open_label = label_for(persisted_mode(existing))
      requested_label = label_for(continuation_mode)
      "This issue already has an open #{open_label} authorization (request ##{existing.id}); " \
        "it must finish or be cancelled before #{article_for(requested_label)} " \
        "#{requested_label} can be requested."
    end

    def label_for(mode)
      MODE_LABELS.fetch(mode, mode)
    end

    def article_for(label)
      label.start_with?(/[aeiou]/) ? "an" : "a"
    end

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

    # A fresh unmet assessment disproves the legacy internal completion
    # attestation. Clear it before canonical admission is calculated so the
    # request-time decision and the later dequeue recheck see the same state.
    def clear_legacy_resolution_with_unmet_work!
      return unless issue.closeout_resolved?

      assessment = PartialCloseouts::Assessment.call(issue)
      return if assessment.stale?
      return unless assessment.criteria.any? { |criterion| criterion["state"] == "unmet" }

      issue.update!(closeout_resolved_at: nil, closeout_resolution_digest: nil, closeout_resolved_by: nil)
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
          evidence: evidence_snapshot(status.evidence).merge("continuation_mode" => continuation_mode),
          evidence_digest: status.evidence.digest
        )
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project: issue.project, goal: goal)
        run = AgentRun.create!(
          project: issue.project,
          issue: issue,
          initiating_user: actor,
          runner_id: runner_id,
          agent_type: agent_type,
          goal: goal,
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
