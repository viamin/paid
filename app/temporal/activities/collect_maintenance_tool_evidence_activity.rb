# frozen_string_literal: true

module Activities
  # Runs only bounded native analyzer adapters after the pinned checkout exists.
  # The adapters execute through AgentRun's existing isolated environment; they
  # never run repository code on the control-plane host.
  # @spec MAINT-040 MAINT-043 MAINT-044 MAINT-045
  class CollectMaintenanceToolEvidenceActivity < BaseActivity
    activity_name "CollectMaintenanceToolEvidence"

    def execute(input)
      agent_run = AgentRun.find(input[:agent_run_id])
      evidence = MaintenanceRuns::ToolEvidence.call(
        run: agent_run,
        time_limit_seconds: input[:time_limit_seconds]
      )
      metadata = agent_run.external_metadata.deep_dup
      metadata["maintenance_tool_evidence"] = evidence.deep_stringify_keys
      agent_run.update!(external_metadata: metadata)
      evidence
    end
  end
end
