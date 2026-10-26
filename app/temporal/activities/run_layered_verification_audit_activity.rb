# frozen_string_literal: true

module Activities
  class RunLayeredVerificationAuditActivity < BaseActivity
    # @spec LAYERED-VERIFY-010, LAYERED-VERIFY-024
    activity_name "RunLayeredVerificationAudit"

    def execute(input)
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      track_phase(agent_run_id: agent_run.id, phase_key: "run_layered_verification_audit", phase_group: "agent", agent_run:) do
        agent_run.start!
        metadata = agent_run.external_metadata.fetch("layered_verification")
        obligations = agent_run.project.layered_verification_obligations.where(id: metadata.fetch("obligation_ids"))
        record_unavailable_checks(agent_run:, obligations:, checks: metadata.dig("plan", "selected_checks") || [])
        coverage = LayeredVerification::Audits::SynthesizeCoverage.call(agent_run:, obligations:)
        agent_run.update!(external_metadata: agent_run.external_metadata.deep_merge("layered_verification" => { "progress" => "completed", "coverage" => coverage.transform_keys(&:id) }))
        agent_run.complete!
        ProcessRunQueueJob.perform_later
        { agent_run_id: agent_run.id, coverage: }
      end
    end

    private

    def record_unavailable_checks(agent_run:, obligations:, checks:)
      obligations.each do |obligation|
        checks.each do |check|
          next if check == "formal_verification"

          LayeredVerificationCheckResult.create!(obligation:, agent_run:, producer: producer_for(check), execution_state: "not_run", obligation_coverage: "unresolved", input_revision: {}, limitations: "The selected #{check} check needs its configured producer before it can run.")
        end
      end
    end

    def producer_for(check)
      return "implementation_conformance" if check.in?(%w[business_to_model business_to_spec spec_to_code model_to_code])
      return "semantic_audit" if check == "semantic_audit"

      check
    end
  end
end
