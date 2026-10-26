# frozen_string_literal: true

module Activities
  class RunLayeredVerificationAuditActivity < BaseActivity
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-024
    activity_name "RunLayeredVerificationAudit"

    def execute(input)
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      track_phase(agent_run_id: agent_run.id, phase_key: "layered_verification_audit", phase_group: "agent", agent_run:) do
        agent_run.start!
        audit = agent_run.external_metadata.fetch("layered_verification_audit")
        obligations = agent_run.project.layered_verification_obligations.where(id: audit.fetch("scope").map { |scope| scope.fetch("id") })
        record_unavailable_checks(agent_run:, obligations:, plan: audit.fetch("plan"))
        record_formal_checks(agent_run:, obligations:, model: audit.dig("plan", "required_inputs", "formal_model"))
        coverage = LayeredVerification::Audits::SynthesizeCoverage.call(agent_run:, obligations: obligations.to_a)
        agent_run.update!(reconciliation: agent_run.reconciliation.merge("layered_verification_coverage" => coverage.transform_keys(&:id)))
        agent_run.complete!
        ProcessRunQueueJob.perform_later
        { agent_run_id: agent_run.id, coverage: coverage.transform_keys(&:id) }
      end
    end

    private

    def record_unavailable_checks(agent_run:, obligations:, plan:)
      plan.fetch("selected_checks").each do |check|
        next unless check.fetch("producer") == "implementation_conformance"

        obligations.each do |obligation|
          LayeredVerificationCheckResult.create!(
            obligation:, agent_run:, producer: check.fetch("producer"), execution_state: "incomplete",
            obligation_coverage: "unresolved", input_revision: { "external_revision" => obligation.external_revision },
            limitations: "The isolated correspondence executor is not available for this audit run."
          )
        end
      end
    end

    def record_formal_checks(agent_run:, obligations:, model:)
      obligations.each do |obligation|
        LayeredVerification::Checks::TlcRunner.call(obligation:, agent_run:, model:)
      end
    end
  end
end
