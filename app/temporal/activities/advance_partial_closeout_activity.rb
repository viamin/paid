# frozen_string_literal: true

module Activities
  # Runs after CreatePullRequestActivity has made the source run terminal, so
  # continuation admission still rejects every other in-flight run on the issue.
  # @spec PARTIAL-CLOSEOUT-024
  class AdvancePartialCloseoutActivity < BaseActivity
    activity_name "AdvancePartialCloseout"

    def execute(input)
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      track_phase(agent_run_id: agent_run.id, phase_key: "advance_partial_closeout",
        phase_group: "post", agent_run: agent_run) do
        assessment = agent_run.reconciliation.fetch("assessment", {})
        result = PartialCloseouts::Advance.call(agent_run: agent_run, assessment: assessment)

        { agent_run_id: agent_run.id, scheduled: result.scheduled?, code: result.code }
      end
    end
  end
end
