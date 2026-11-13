# frozen_string_literal: true

module Activities
  # Records the semantic closeout authority before publishing a source PR.
  class AssessSourceClosureActivity < BaseActivity
    activity_name "AssessSourceClosure"
    MAX_ASSESSMENT_TIMEOUT_WITH_FALLBACK = 100

    def execute(input) # @spec PARTIAL-CLOSEOUT-029
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      return { agent_run_id: agent_run.id, disposition: "track" } unless agent_run.issue

      track_phase(agent_run_id: agent_run.id, phase_key: "assess_source_closure", phase_group: "post", agent_run: agent_run) do
        assessment = agent_run.reconciliation["assessment"] || begin
          fallbacks = Llm::AnalyzePartialCloseout.fallback_runner_identifiers_for(agent_run)
          timeout = fallbacks.any? ? MAX_ASSESSMENT_TIMEOUT_WITH_FALLBACK : Llm::AnalyzePartialCloseout::TIMEOUT
          result = Llm::AnalyzePartialCloseout.call(agent_run: agent_run,
            fallback_runner_identifiers: fallbacks, timeout: timeout)
          PartialCloseouts::Assessment.snapshot(agent_run, result)
        end
        agent_run.update!(reconciliation: agent_run.reconciliation.merge("assessment" => assessment))
        disposition = PartialCloseouts::SourceClosureDisposition.record!(agent_run, assessment: assessment)
        { agent_run_id: agent_run.id, disposition: disposition.fetch("disposition") }
      end
    rescue Llm::AnalyzePartialCloseout::AssessmentFailure => e
      category = e.diagnostic.fetch(:category, "transport_error")
      raise Temporalio::Error::ApplicationError.new(
        e.message, { "category" => category }, type: "SourceClosureAssessmentFailure",
        non_retryable: !recoverable_category?(category)
      )
    rescue AgentHarness::ConfigurationError
      raise Temporalio::Error::ApplicationError.new(
        "Partial closeout assessment configuration is unavailable. Review the configured runner and retry.",
        { "category" => "configuration_unavailable" },
        type: "SourceClosureAssessmentFailure", non_retryable: true
      )
    end

    private

    def recoverable_category?(category) = Llm::AnalyzePartialCloseout::RECOVERABLE_CATEGORIES.include?(category)
  end
end
