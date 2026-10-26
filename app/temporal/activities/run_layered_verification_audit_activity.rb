# frozen_string_literal: true

module Activities
  class RunLayeredVerificationAuditActivity < BaseActivity
    # @spec LAYERED-VERIFY-010
    # @spec LAYERED-VERIFY-024
    activity_name "RunLayeredVerificationAudit"

    def execute(input)
      audit_run = AgentRun.find(input.fetch(:agent_run_id))
      track_phase(agent_run_id: audit_run.id, phase_key: "layered_verification_audit", phase_group: "agent", agent_run: audit_run) do
        audit_run.start!
        report = LayeredVerification::Audits::Run.call(audit_run:)
        audit_run.update!(verification_result: audit_run.verification_result.merge("layered_verification_audit" => report))
        audit_run.complete!
        ProcessRunQueueJob.perform_later
        report.merge(agent_run_id: audit_run.id)
      end
    end
  end
end
