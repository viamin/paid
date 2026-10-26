# frozen_string_literal: true

module Activities
  # Records the semantic closeout authority before publishing a source PR.
  class AssessSourceClosureActivity < BaseActivity
    activity_name "AssessSourceClosure"

    def execute(input) # @spec PARTIAL-CLOSEOUT-029
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      return { agent_run_id: agent_run.id, disposition: "track" } unless agent_run.issue

      track_phase(agent_run_id: agent_run.id, phase_key: "assess_source_closure", phase_group: "post", agent_run: agent_run) do
        assessment = agent_run.reconciliation["assessment"] || begin
          result = Llm::AnalyzePartialCloseout.call(agent_run: agent_run)
          PartialCloseouts::Assessment.snapshot(agent_run, result)
        end
        agent_run.update!(reconciliation: agent_run.reconciliation.merge("assessment" => assessment))
        disposition = PartialCloseouts::SourceClosureDisposition.record!(agent_run, assessment: assessment)
        { agent_run_id: agent_run.id, disposition: disposition.fetch("disposition") }
      end
    end
  end
end
