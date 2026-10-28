# frozen_string_literal: true

module Activities
  class ReconcilePartialCloseoutActivity < BaseActivity
    activity_name "ReconcilePartialCloseout"

    def execute(input) # @spec NO-OUTPUT-ISSUE-007 PARTIAL-CLOSEOUT-034
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      track_phase(agent_run_id: agent_run.id, phase_key: "reconcile_partial_closeout",
        phase_group: "post", agent_run: agent_run) do
        # Issue-less PR runs (scheduled sweeps, MCP custom prompts) have no
        # approved issue intent to reconcile against. The analyzer would crash
        # on agent_run.issue and fail the run after the PR was already pushed;
        # mirror UpdateIssueWithPrActivity's guard instead.
        return { agent_run_id: agent_run.id, status: "skipped_no_issue", gaps_remain: false } unless agent_run.issue

        assessment = persisted_assessment(agent_run)
        PartialCloseouts::SourceClosureDisposition.record!(agent_run, assessment: assessment)
        PartialCloseouts::Reconcile.call(agent_run: agent_run, assessment: assessment)
        { agent_run_id: agent_run.id, status: agent_run.reload.reconciliation.fetch("status"),
          gaps_remain: gaps_remain?(agent_run) }
      end
    rescue Llm::AnalyzePartialCloseout::AssessmentError => error
      persist_assessment_failure!(agent_run, error)
      { agent_run_id: agent_run.id, status: "assessment_unavailable", gaps_remain: true }
    rescue StandardError => e
      agent_run&.update!(reconciliation: agent_run.reconciliation.merge("status" => "retryable_failure", "error" => e.message))
      raise
    end

    private

    # The workflow cannot query the database (deterministic replay), so the
    # activity result must tell it whether any gaps remain. The persisted
    # status alone is ambiguous: "reconciled" covers both a gap-free closeout
    # and one whose gaps all received agent owners — and in both gap cases the
    # parent must stay incomplete, so the raw assessment gap count is the
    # signal.
    def gaps_remain?(agent_run)
      agent_run.reconciliation["status"] == "assessment_unavailable" || Array(agent_run.reconciliation.dig("assessment", "gaps")).present?
    end

    # The assessment is the deterministic input for the deterministic
    # reconciler: persist it on first success and reuse it on retry so gap
    # indices (the replay keys) stay stable across attempts instead of
    # re-invoking the LLM, which may return a different gap set or order.
    def persisted_assessment(agent_run)
      agent_run.reconciliation["assessment"] || Llm::AnalyzePartialCloseout.call(agent_run: agent_run).then do |result|
        PartialCloseouts::Assessment.snapshot(agent_run, result).tap do |assessment|
          agent_run.update!(reconciliation: agent_run.reconciliation.merge("assessment" => assessment))
        end
      end
    end

    def persist_assessment_failure!(agent_run, error)
      details = {
        "category" => error.category.to_s, "provider" => error.provider.to_s, "model" => error.model,
        "request_id" => error.request_id, "attempt_id" => error.attempt_id,
        "invalid_fields" => error.invalid_fields.first(10), "recovery" => error.message
      }
      agent_run.update!(reconciliation: agent_run.reconciliation.merge(
        "status" => "assessment_unavailable", "assessment_failure" => details, "failed_at" => Time.current.iso8601
      ))
      Rails.logger.warn(message: "partial_closeouts.assessment_unavailable", agent_run_id: agent_run.id,
        failure_category: error.category, provider: error.provider, model: error.model,
        request_id: error.request_id, attempt_id: error.attempt_id, invalid_field_count: error.invalid_fields.size)
    end
  end
end
