# frozen_string_literal: true

module Activities
  # Records the semantic closeout authority before publishing a source PR.
  class AssessSourceClosureActivity < BaseActivity
    activity_name "AssessSourceClosure"

    # Typed failure so the workflow can tell an assessment failure apart from
    # any other activity error and park the run for recovery.
    FAILURE_TYPE = "SourceClosureAssessmentFailed"

    def execute(input) # @spec PARTIAL-CLOSEOUT-029 @spec PARTIAL-CLOSEOUT-042
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      return { agent_run_id: agent_run.id, disposition: "track" } unless agent_run.issue

      track_phase(agent_run_id: agent_run.id, phase_key: "assess_source_closure", phase_group: "post", agent_run: agent_run) do
        assessment = agent_run.reconciliation["assessment"] || begin
          result = assess(agent_run)
          PartialCloseouts::Assessment.snapshot(agent_run, result)
        end
        agent_run.update!(reconciliation: agent_run.reconciliation.merge("assessment" => assessment))
        disposition = PartialCloseouts::SourceClosureDisposition.record!(agent_run, assessment: assessment)
        { agent_run_id: agent_run.id, disposition: disposition.fetch("disposition") }
      end
    end

    private

    # A failed assessment is recorded as a durable attempt before it is
    # re-raised, so the run keeps the failed step, the pushed revision, the
    # attempt count, and the sanitized failure category even when the process
    # restarts between attempts.
    # @spec PARTIAL-CLOSEOUT-043
    def assess(agent_run)
      Llm::AnalyzePartialCloseout.call(agent_run: agent_run)
    rescue Llm::AnalyzePartialCloseout::AssessmentFailure => e
      raise failure(agent_run, e)
    rescue AgentHarness::ConfigurationError => e
      raise failure(agent_run, e)
    end

    def failure(agent_run, error)
      PartialCloseouts::SourceClosureRecoveryState.record_attempt(
        agent_run,
        error: error,
        branch: agent_run.branch_name,
        commit_sha: agent_run.result_commit_sha
      )
      category = Llm::PartialCloseoutFailure.category_for(error)
      Temporalio::Error::ApplicationError.new(
        error.message,
        type: FAILURE_TYPE,
        non_retryable: !Llm::PartialCloseoutFailure.retryable?(category)
      )
    end
  end
end
