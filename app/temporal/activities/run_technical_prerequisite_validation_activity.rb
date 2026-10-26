# frozen_string_literal: true

module Activities
  # @spec PARTIAL-CLOSEOUT-030
  class RunTechnicalPrerequisiteValidationActivity < BaseActivity
    activity_name "RunTechnicalPrerequisiteValidation"

    def execute(input)
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      track_phase(agent_run_id: agent_run.id, phase_key: "run_technical_prerequisite_validation",
        phase_group: "agent", agent_run: agent_run) do
        agent_run.start!
        result = PartialCloseouts::PrerequisiteValidation.call(agent_run: agent_run)
        agent_run.complete!
        ProcessRunQueueJob.perform_later
        { agent_run_id: agent_run.id, technical_prerequisite_validation: result.status }
      end
    end
  end
end
